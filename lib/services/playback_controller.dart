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
import 'runtime_environment.dart';
import 'playback_tuning.dart';
import 'playback_startup.dart';

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
  }) : isEmulator = emulatorCheck ?? RuntimeEnvironment.isEmulator,
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
    network = (connectivityChanges ?? Connectivity().onConnectivityChanged)
        .listen((links) {
          if (active &&
              (links.contains(ConnectivityResult.none) ||
                  !links.contains(ConnectivityResult.wifi))) {
            unawaited(stop(message: '回線が変わったため視聴・リレーを停止しました'));
          }
        });
    logs = player?.stream.log.listen((entry) {
      if (kDebugMode) debugPrint('Playback: $entry');
      if (active &&
          entry.level == 'fatal' &&
          (entry.prefix.startsWith('vo/') ||
              entry.text.contains('video_out'))) {
        unawaited(stop(message: '映像を表示できませんでした。端末の動画再生機能を確認してください'));
      }
    });
    errors = player?.stream.error.listen((e) {
      if (active) unawaited(stop(message: '再生できませんでした: $e'));
    });
  }
  final Future<bool> Function() isEmulator;
  final DateTime Function() now;
  final AppSettings settings;
  final EngineBackend engine;
  final _audioSession = PlaybackAudioSession();
  final Player? player;
  final Future<List<ConnectivityResult>> Function() checkConnectivity;
  final Future<Directory> Function() supportDirectory;
  late final VideoController video = VideoController(player!);
  final VideoPlayerController Function(Uri)? androidVideoFactory;
  VideoPlayerController? androidVideo;
  bool _recoveringVideo = false;
  int _videoRetries = 0;
  DateTime? _videoStartedAt;
  late final StreamSubscription<List<ConnectivityResult>> network;
  late final StreamSubscription<String>? errors;
  late final StreamSubscription<PlayerLog>? logs;
  EngineSnapshot snapshot = const EngineSnapshot();
  String message = '停止中';
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
    active = true;
    opening = true;
    final port = settings.port;
    String portFailure() =>
        'ポート $port の開放を確認できません。${snapshot.portCheckError.isEmpty ? 'Wi-FiとiPhoneへのポート転送設定を確認してください' : snapshot.portCheckError}';
    message = '接続中…';
    changed();
    try {
      if (!channel.playable) throw StateError('${channel.format} は再生対象外です');
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
            if (androidVideo != null) {
              unawaited(_recoverAndroidVideo(uri, ticket, '中継の受信再開'));
            } else {
              message = '視聴中';
            }
          }
          if (requireOpenPort &&
              now().difference(lastPortCheck).inSeconds >= 15) {
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
      if (Platform.isAndroid || androidVideoFactory != null) {
        await _openAndroidVideo(uri, ticket);
      } else {
        simulatorAudioUnavailable = await _audioSession.activate();
        if (_disposed || ticket != _generation) return;
        final nativePlayer = player!.platform;
        if (nativePlayer is NativePlayer) {
          await configureNativePlayback(
            nativePlayer.setProperty,
            silentSimulator: simulatorAudioUnavailable,
          );
        }
        if (_disposed || ticket != _generation) return;
        await player!.setVolume(muted ? 0 : 100);
        final startup = PlaybackStartup(player!.stream.position);
        _startup = startup;
        try {
          // Subscribe before open: it completes when the load is queued, not
          // when decoding starts. Wait for both, with errors observed together.
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

  bool _isCurrent(int ticket) => !_disposed && active && ticket == _generation;

  Future<void> _openAndroidVideo(Uri uri, int ticket) async {
    final previous = androidVideo;
    androidVideo = null;
    changed();
    await previous?.dispose();
    if (!_isCurrent(ticket)) return;
    final output =
        androidVideoFactory?.call(uri) ?? VideoPlayerController.networkUrl(uri);
    androidVideo = output;
    var ready = false;
    output.addListener(() {
      // Initialization errors are handled by the awaiting caller. Ignore
      // notifications from players replaced during recovery or channel changes.
      if (ready &&
          _isCurrent(ticket) &&
          identical(androidVideo, output) &&
          (output.value.hasError || output.value.isCompleted)) {
        unawaited(
          _recoverAndroidVideo(uri, ticket, output.value.errorDescription),
        );
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
    _recoveringVideo = false;
    _videoRetries = 0;
    _videoStartedAt = null;
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
          await engine.stop();
        } catch (e) {
          this.message = '停止処理を確認できませんでした: $e';
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
      stop().whenComplete(() async {
        await player?.dispose();
      }),
    );
    super.dispose();
  }
}
