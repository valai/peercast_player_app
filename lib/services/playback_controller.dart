import 'dart:async';
import 'dart:io';

import 'package:video_player/video_player.dart';

import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../models/channel.dart';
import 'app_settings.dart';
import 'peercast_engine.dart';
import 'playback_audio_session.dart';
import 'playback_background.dart';
import 'runtime_environment.dart';
import 'playback_tuning.dart';
import 'playback_startup.dart';
import 'hls_loopback_proxy.dart';
import 'windows_mobile_api.dart';

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.settings,
    EngineBackend? engine,
    Future<List<ConnectivityResult>> Function()? connectivityCheck,
    Stream<List<ConnectivityResult>>? connectivityChanges,
    Future<Directory> Function()? supportDirectory,
    Player? Function()? playerFactory,
    DateTime Function()? now,
    Future<bool> Function()? emulatorCheck,
    this.androidVideoFactory,
    PlaybackBackground? background,
    WindowsCredentialStore? credentialStore,
    WindowsMobileApi Function(WindowsCredentials)? windowsApiFactory,
    this.confirmWindowsSwitch,
  }) : background = background ?? PlaybackBackground(),
       credentialStore = credentialStore ?? WindowsCredentialStore(),
       windowsApiFactory = windowsApiFactory ?? WindowsMobileApi.new,
       isEmulator = emulatorCheck ?? RuntimeEnvironment.isEmulator,
       now = now ?? DateTime.now,
       engine = engine ?? PeerCastEngine(),
       checkConnectivity =
           connectivityCheck ?? Connectivity().checkConnectivity,
       supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       player = playerFactory != null
           ? playerFactory()
           : (Platform.isAndroid
                 ? null
                 : Player(
                     configuration: const PlayerConfiguration(
                       logLevel: kDebugMode
                           ? MPVLogLevel.info
                           : MPVLogLevel.error,
                     ),
                   )) {
    this.background.onStop = () => unawaited(stop());
    network = (connectivityChanges ?? Connectivity().onConnectivityChanged)
        .listen((links) {
          if (active &&
              !_windowsMode &&
              (links.contains(ConnectivityResult.none) ||
                  !links.contains(ConnectivityResult.wifi))) {
            unawaited(stop(message: '回線が変わったため視聴・リレーを停止しました'));
          }
        });
    logs = player?.stream.log.listen((entry) {
      if (active &&
          entry.level == 'fatal' &&
          (entry.prefix.startsWith('vo/') ||
              entry.text.contains('video_out'))) {
        unawaited(stop(message: '映像を表示できませんでした。端末の動画再生機能を確認してください'));
      }
    });
    errors = player?.stream.error.listen((e) {
      if (active) {
        if (_windowsMode) {
          _windowsDisconnected = true;
          message = 'Windowsとの再接続を待っています…';
          changed();
        } else {
          unawaited(stop(message: '再生できませんでした: $e'));
        }
      }
    });
  }
  final Future<bool> Function() isEmulator;
  final DateTime Function() now;
  final AppSettings settings;
  final WindowsCredentialStore credentialStore;
  final WindowsMobileApi Function(WindowsCredentials) windowsApiFactory;
  final Future<bool> Function()? confirmWindowsSwitch;
  final EngineBackend engine;
  final PlaybackBackground background;
  final _audioSession = PlaybackAudioSession();
  final Player? player;
  final Future<List<ConnectivityResult>> Function() checkConnectivity;
  final Future<Directory> Function() supportDirectory;
  late final VideoController video = VideoController(player!);
  final VideoPlayerController Function(Uri)? androidVideoFactory;
  bool get usesAndroidVideo =>
      Platform.isAndroid || androidVideoFactory != null;
  VideoPlayerController? androidVideo;
  bool _recoveringVideo = false;
  int _videoRetries = 0;
  DateTime? _videoStartedAt;
  Duration? _androidPosition;
  DateTime? _androidProgressAt;
  late final StreamSubscription<List<ConnectivityResult>> network;
  late final StreamSubscription<String>? errors;
  late final StreamSubscription<PlayerLog>? logs;
  EngineSnapshot snapshot = const EngineSnapshot();
  String message = '停止中';
  bool _windowsMode = false;
  bool get windowsMode => _windowsMode;
  WindowsSessionStatus? windowsStatus;
  WindowsMobileApi? _windowsApi;
  HlsLoopbackProxy? _windowsProxy;
  bool _ownsWindowsSession = false;
  bool _windowsDisconnected = false;
  bool _windowsReopening = false;
  String? _windowsSessionId;
  bool muted = false;

  Future<void> toggleMute() async {
    muted = !muted;
    changed();
    await androidVideo?.setVolume(muted ? 0 : 1);
    await player?.setVolume(muted ? 0 : 100);
  }

  bool active = false, opening = false;
  bool simulatorAudioUnavailable = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? timer;
  PlaybackStartup? _startup;
  bool _polling = false;
  Future<void> _cleanup = Future.value();
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(Channel channel) async {
    final cleanup = stop();
    final ticket = _generation;
    await cleanup;
    if (_disposed || ticket != _generation) return;
    _windowsMode = settings.playbackSource == PlaybackSource.windows;
    if (_windowsMode) {
      await _startWindows(channel, ticket);
      return;
    }
    active = true;
    opening = true;
    final port = settings.port;
    String portFailure() =>
        'ポート $port の開放を確認できません。${snapshot.portCheckError.isEmpty ? 'Wi-FiとiPhoneへのポート転送設定を確認してください' : snapshot.portCheckError}';
    message = '接続中…';
    changed();
    try {
      if (!channel.playable) throw StateError('${channel.format} は再生対象外です');
      await background.start(channel.name);
      if (_disposed || ticket != _generation) return;
      final links = await checkConnectivity();
      if (_disposed || ticket != _generation) return;
      if (!links.contains(ConnectivityResult.wifi)) {
        throw StateError('Wi-Fiに接続してください');
      }
      if (links.contains(ConnectivityResult.none)) {
        throw StateError('ネットワークに接続してください');
      }
      final requireOpenPort = !await isEmulator();
      if (_disposed || ticket != _generation) return;
      final directory = await supportDirectory();
      if (_disposed || ticket != _generation) return;
      final uri = await engine.start(
        channel,
        directory.path,
        port,
        settings.maxRelays,
      );
      if (_disposed || ticket != _generation) return;
      if (requireOpenPort) {
        message = 'ポート $port の開放を確認中…';
        changed();
        await engine.checkPort(channel);
        final portDeadline = now().add(const Duration(seconds: 35));
        while (true) {
          if (_disposed || ticket != _generation) return;
          snapshot = await engine.snapshot();
          if (_disposed || ticket != _generation) return;
          if (snapshot.firewall == 'reachable') break;
          if (!snapshot.running ||
              snapshot.firewall == 'blocked' ||
              now().isAfter(portDeadline)) {
            throw StateError(portFailure());
          }
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      final currentLinks = await checkConnectivity();
      if (_disposed || ticket != _generation) return;
      if (!currentLinks.contains(ConnectivityResult.wifi) ||
          currentLinks.contains(ConnectivityResult.none)) {
        throw StateError('Wi-Fiに接続してください');
      }
      await engine.connect(channel);
      if (_disposed || ticket != _generation) return;
      var lastPortCheck = now();
      DateTime? disconnectedAt;
      var playbackStarted = false;
      timer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (_polling || !active) return;
        _polling = true;
        try {
          final links = await checkConnectivity();
          if (_disposed || ticket != _generation) return;
          if (!links.contains(ConnectivityResult.wifi) ||
              links.contains(ConnectivityResult.none)) {
            await stop(message: 'Wi-Fi接続が失われたため視聴・リレーを停止しました');
            return;
          }
          final next = await engine.snapshot();
          if (_disposed || ticket != _generation) return;
          snapshot = next;
          if (!next.running ||
              (background.running && !next.listening) ||
              (requireOpenPort && next.firewall != 'reachable')) {
            await stop(message: portFailure());
            return;
          }
          // isPlaying describes the current relay, not whether the broadcast
          // has ended. Let the core search for another upstream before stopping.
          if (playbackStarted && !next.playing) {
            disconnectedAt ??= now();
            message = '中継との接続が途切れたため再接続を待っています…';
            if (now().difference(disconnectedAt!) >=
                const Duration(minutes: 2)) {
              await stop(
                message:
                    '中継との接続を2分間復旧できませんでした。再度再生してください。\n'
                    '${next.connectionTimeoutMessage}',
              );
              return;
            }
          } else if (next.playing && disconnectedAt != null) {
            disconnectedAt = null;
            if (androidVideo?.value.hasError == true) {
              unawaited(_recoverAndroidVideo(uri, ticket, '中継の受信再開'));
            } else {
              message = '視聴中';
            }
          }
          await _checkAndroidProgress(uri, ticket);
          if (!_isCurrent(ticket)) return;
          if (requireOpenPort &&
              now().difference(lastPortCheck) >= const Duration(minutes: 5)) {
            lastPortCheck = now();
            await engine.checkPort(channel);
          }
          changed();
        } catch (e) {
          if (ticket == _generation) await stop(message: '接続状態を確認できませんでした: $e');
        } finally {
          _polling = false;
        }
      });
      final deadline = now().add(const Duration(seconds: 60));
      while (active && ticket == _generation) {
        snapshot = await engine.snapshot();
        if (_disposed || ticket != _generation) return;
        changed();
        if (requireOpenPort && snapshot.firewall != 'reachable') {
          throw StateError('ポート開放を確認できないため停止しました');
        }
        if (snapshot.playing) break;
        if (!snapshot.running) {
          throw StateError('視聴エンジンを開始できませんでした。待受ポートを確認してください');
        }
        if (now().isAfter(deadline)) {
          throw TimeoutException(snapshot.connectionTimeoutMessage);
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (_disposed || ticket != _generation) return;
      await _openVideo(uri, ticket);
      if (_disposed || ticket != _generation) return;
      playbackStarted = true;
      opening = false;
      message = '視聴中';
      changed();
    } catch (e) {
      if (!_disposed && ticket == _generation) {
        await stop(message: e is StateError ? e.message : '$e');
      }
    }
  }

  Future<void> _openVideo(Uri uri, int ticket) async {
    if (usesAndroidVideo) {
      await _openAndroidVideo(uri, ticket);
      return;
    }
    simulatorAudioUnavailable = await _audioSession.activate();
    if (!_isCurrent(ticket)) return;
    final nativePlayer = player!.platform;
    if (nativePlayer is NativePlayer) {
      await configureNativePlayback(
        nativePlayer.setProperty,
        silentSimulator: simulatorAudioUnavailable,
      );
    }
    if (!_isCurrent(ticket)) return;
    await player!.setVolume(muted ? 0 : 100);
    final startup = PlaybackStartup(player!.stream.position);
    _startup = startup;
    try {
      final results = await Future.wait<Object?>([
        startup.ready,
        player!
            .open(Media(uri.toString()))
            .timeout(const Duration(seconds: 30)),
      ], eagerError: true);
      if (results.first != true) return;
    } finally {
      startup.cancel();
      if (identical(_startup, startup)) _startup = null;
    }
  }

  Future<void> _startWindows(Channel channel, int ticket) async {
    active = true;
    opening = true;
    message = 'Windowsに接続中…';
    changed();
    try {
      if (!channel.playable) throw StateError('${channel.format} は再生対象外です');
      final credentials = await credentialStore.read();
      if (!_isCurrent(ticket)) return;
      if (credentials == null) throw StateError('設定からWindowsとペアリングしてください');
      final api = windowsApiFactory(credentials);
      _windowsApi = api;
      await background.start(channel.name);
      if (!_isCurrent(ticket)) return;
      String sessionId;
      try {
        sessionId = await api.start(channel);
      } on WindowsApiException catch (error) {
        if (error.statusCode != 409) rethrow;
        final replace =
            await (confirmWindowsSwitch?.call() ?? Future.value(false));
        if (!_isCurrent(ticket)) return;
        if (!replace) throw StateError('Windowsで別の番組を視聴中です');
        await api.stop();
        if (!_isCurrent(ticket)) return;
        sessionId = await api.start(channel);
      }
      if (!_isCurrent(ticket)) return;
      _ownsWindowsSession = true;
      _windowsSessionId = sessionId;
      message = 'Windowsで映像を準備中…';
      changed();
      final deadline = now().add(const Duration(seconds: 60));
      WindowsSessionStatus status;
      while (true) {
        status = await api.status();
        if (!_isCurrent(ticket)) return;
        windowsStatus = status;
        changed();
        if (status.sessionId != sessionId) {
          _ownsWindowsSession = false;
          throw StateError('Windows側の視聴が切り替わりました');
        }
        if (status.state == 'ready') break;
        if (status.state == 'failed') {
          throw StateError(status.error ?? 'Windowsで変換できませんでした');
        }
        if (status.state != 'starting' || now().isAfter(deadline)) {
          throw StateError('Windowsで映像を準備できませんでした');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!_isCurrent(ticket)) return;
      }
      final proxy = await HlsLoopbackProxy.bind(credentials, status);
      if (!_isCurrent(ticket)) {
        await proxy.close();
        return;
      }
      _windowsProxy = proxy;
      final uri = proxy.playlist(status, settings.windowsQuality.name);
      await _openVideo(uri, ticket);
      if (!_isCurrent(ticket)) return;
      opening = false;
      message = 'Windows経由で視聴中';
      changed();
      timer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_pollWindows(ticket)),
      );
    } on WindowsApiException catch (error) {
      if (_isCurrent(ticket)) {
        if (error.statusCode == 401) await credentialStore.delete();
        await stop(message: error.message);
      }
    } catch (error) {
      if (_isCurrent(ticket)) {
        await stop(
          message: error is StateError ? error.message : 'Windows経由で再生できませんでした',
        );
      }
    }
  }

  Future<void> _pollWindows(int ticket) async {
    if (!_isCurrent(ticket) || _polling || _windowsApi == null) return;
    _polling = true;
    try {
      final status = await _windowsApi!.status();
      if (!_isCurrent(ticket)) return;
      windowsStatus = status;
      if (status.sessionId != _windowsSessionId || status.state == 'idle') {
        _ownsWindowsSession = false;
        await stop(message: 'Windows側の視聴が終了しました。再度開始してください');
        return;
      }
      if (status.state == 'failed') {
        await stop(message: status.error ?? 'Windowsで変換が終了しました');
        return;
      }
      if (_windowsDisconnected &&
          status.state == 'ready' &&
          !_windowsReopening) {
        _windowsReopening = true;
        try {
          final uri = _windowsProxy!.playlist(
            status,
            settings.windowsQuality.name,
          );
          await _openVideo(uri, ticket);
          if (!_isCurrent(ticket)) return;
          _windowsDisconnected = false;
          opening = false;
          message = 'Windows経由で視聴中';
        } finally {
          _windowsReopening = false;
        }
      }
      changed();
    } on WindowsApiException catch (error) {
      if (!_isCurrent(ticket)) return;
      if (error.statusCode == 401) {
        await credentialStore.delete();
        await stop(message: error.message);
      } else {
        _windowsDisconnected = true;
        opening = true;
        message = 'Windowsとの再接続を待っています…';
        changed();
      }
    } catch (_) {
      if (_isCurrent(ticket)) {
        _windowsDisconnected = true;
        opening = true;
        message = 'Windowsとの再接続を待っています…';
        changed();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> changeWindowsQuality(WindowsQuality quality) async {
    final previous = settings.windowsQuality;
    settings.windowsQuality = quality;
    try {
      await settings.save();
    } catch (_) {
      settings.windowsQuality = previous;
      message = '画質設定を保存できませんでした';
      changed();
      return;
    }
    final ticket = _generation;
    final status = windowsStatus;
    final proxy = _windowsProxy;
    if (!_isCurrent(ticket) ||
        !_windowsMode ||
        status == null ||
        proxy == null) {
      return;
    }
    try {
      opening = true;
      changed();
      final uri = proxy.playlist(status, quality.name);
      await _openVideo(uri, ticket);
      if (_isCurrent(ticket)) {
        opening = false;
        message = 'Windows経由で視聴中';
        changed();
      }
    } catch (_) {
      if (_isCurrent(ticket)) await stop(message: '画質を切り替えられませんでした');
    }
  }

  bool _isCurrent(int ticket) => !_disposed && active && ticket == _generation;

  Future<void> _checkAndroidProgress(Uri uri, int ticket) async {
    final output = androidVideo;
    if (output == null || !output.value.isInitialized || _recoveringVideo) {
      return;
    }
    // value.position is clamped to duration (often zero for live FLV), and
    // isCompleted is derived from that same value. Read the native clock instead.
    Duration? position;
    try {
      position = await output.position.timeout(const Duration(seconds: 5));
    } catch (e) {
      if (_isCurrent(ticket) && identical(androidVideo, output)) {
        unawaited(_recoverAndroidVideo(uri, ticket, '再生位置を取得できませんでした: $e'));
      }
      return;
    }
    if (!_isCurrent(ticket) || !identical(androidVideo, output)) return;
    if (!snapshot.playing || position == null || position != _androidPosition) {
      _androidPosition = position;
      _androidProgressAt = now();
      return;
    }
    _androidProgressAt ??= now();
    if (now().difference(_androidProgressAt!) >= const Duration(seconds: 30)) {
      unawaited(_recoverAndroidVideo(uri, ticket, '再生位置が30秒間進みませんでした'));
    }
  }

  Future<void> _openAndroidVideo(Uri uri, int ticket) async {
    final previous = androidVideo;
    androidVideo = null;
    changed();
    await previous?.dispose();
    if (!_isCurrent(ticket)) return;
    final output =
        androidVideoFactory?.call(uri) ??
        VideoPlayerController.networkUrl(
          uri,
          videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
        );
    androidVideo = output;
    var ready = false;
    output.addListener(() {
      // Initialization errors are handled by the awaiting caller. Ignore
      // notifications from players replaced during recovery or channel changes.
      if (ready &&
          _isCurrent(ticket) &&
          identical(androidVideo, output) &&
          output.value.hasError) {
        if (_windowsMode) {
          _windowsDisconnected = true;
          opening = true;
          message = 'Windowsとの再接続を待っています…';
          changed();
          unawaited(_pollWindows(ticket));
        } else {
          unawaited(
            _recoverAndroidVideo(uri, ticket, output.value.errorDescription),
          );
        }
      }
    });
    await output.initialize().timeout(const Duration(seconds: 30));
    if (!_isCurrent(ticket)) return;
    await output.setVolume(muted ? 0 : 1);
    if (!_isCurrent(ticket)) return;
    await output.play();
    if (!_isCurrent(ticket)) return;
    if (output.value.hasError) {
      throw StateError(output.value.errorDescription ?? '動画再生エラー');
    }
    _videoStartedAt = now();
    _androidPosition = null;
    _androidProgressAt = now();
    ready = true;
  }

  Future<void> _recoverAndroidVideo(Uri uri, int ticket, String? error) async {
    if (!_isCurrent(ticket) || _recoveringVideo) return;
    _recoveringVideo = true;
    // A short-lived successful initialize must not allow an infinite retry loop.
    if (_videoStartedAt != null &&
        now().difference(_videoStartedAt!) >= const Duration(minutes: 2)) {
      _videoRetries = 0;
    }
    opening = true;
    try {
      while (_isCurrent(ticket) && _videoRetries < 3) {
        // Upstream recovery is bounded by the polling deadline. Do not spend
        // decoder retries while the local stream has no upstream data.
        if (!snapshot.playing) {
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        final attempt = ++_videoRetries;
        debugPrint('Android playback recovery $attempt/3: $error');
        message = '再生が途切れたため再接続中…（$attempt/3）';
        changed();
        await Future<void>.delayed(Duration(seconds: attempt));
        if (!_isCurrent(ticket)) return;
        try {
          await _openAndroidVideo(uri, ticket);
          if (!_isCurrent(ticket)) return;
          opening = false;
          message = '視聴中';
          changed();
          return;
        } catch (e) {
          error = '$e';
        }
      }
      if (_isCurrent(ticket)) {
        await stop(message: '再生を復旧できませんでした。再度再生してください: $error');
      }
    } finally {
      if (ticket == _generation) _recoveringVideo = false;
    }
  }

  Future<void> stop({String message = '停止中'}) {
    ++_generation;
    final wasWindows = _windowsMode;
    final windowsApi = _windowsApi;
    final windowsProxy = _windowsProxy;
    final ownedWindowsSession = _ownsWindowsSession;
    _windowsMode = false;
    _windowsApi = null;
    _windowsProxy = null;
    _ownsWindowsSession = false;
    _windowsDisconnected = false;
    _windowsSessionId = null;
    windowsStatus = null;
    _recoveringVideo = false;
    _videoRetries = 0;
    _videoStartedAt = null;
    _androidPosition = null;
    _androidProgressAt = null;
    _startup?.cancel();
    _startup = null;
    active = false;
    opening = false;
    timer?.cancel();
    timer = null;
    this.message = message;
    changed();
    _cleanup = _cleanup.then((_) async {
      // Stop networking and media together; native cleanup may take time.
      final stoppingEngine = () async {
        try {
          if (wasWindows) {
            if (ownedWindowsSession) await windowsApi?.stop();
            await windowsProxy?.close();
            windowsApi?.dispose();
          } else {
            await engine.stop();
          }
        } catch (e) {
          if (!wasWindows) this.message = '停止処理を確認できませんでした: $e';
        } finally {
          if (wasWindows) {
            await windowsProxy?.close();
            windowsApi?.dispose();
          }
        }
      }();
      try {
        final output = androidVideo;
        androidVideo = null;
        if (output != null) await output.dispose();
        await player?.stop();
      } catch (_) {
        /* Already disposed. */
      }
      try {
        await _audioSession.deactivate();
      } catch (e) {
        if (kDebugMode) debugPrint('Audio session cleanup: $e');
      }
      await stoppingEngine;
      await background.stop();
      snapshot = const EngineSnapshot();
      changed();
    });
    return _cleanup;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(network.cancel());
    unawaited(errors?.cancel());
    unawaited(logs?.cancel());
    unawaited(
      (active ? stop() : _cleanup).whenComplete(() async {
        await player?.dispose();
        background.dispose();
      }),
    );
    super.dispose();
  }
}
