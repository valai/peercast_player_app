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

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.settings,
    EngineBackend? engine,
    Future<List<ConnectivityResult>> Function()? connectivityCheck,
    Stream<List<ConnectivityResult>>? connectivityChanges,
    Future<Directory> Function()? supportDirectory,
    Player? Function()? playerFactory,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
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
  final DateTime Function() now;
  final AppSettings settings;
  final EngineBackend engine;
  final _audioSession = PlaybackAudioSession();
  final Player? player;
  final Future<List<ConnectivityResult>> Function() checkConnectivity;
  final Future<Directory> Function() supportDirectory;
  late final VideoController video = VideoController(player!);
  VideoPlayerController? androidVideo;
  late final StreamSubscription<List<ConnectivityResult>> network;
  late final StreamSubscription<String>? errors;
  late final StreamSubscription<PlayerLog>? logs;
  EngineSnapshot snapshot = const EngineSnapshot();
  String message = '停止中';
  bool active = false, opening = false;
  bool simulatorAudioUnavailable = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? timer;
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
      final directory = await supportDirectory();
      if (_disposed || ticket != _generation) return;
      final uri = await engine.start(
        channel,
        directory.path,
        settings.port,
        settings.maxRelays,
      );
      if (_disposed || ticket != _generation) return;
      message = 'ポート開放を確認中…';
      changed();
      await engine.checkPort(channel.tracker);
      final portDeadline = now().add(const Duration(seconds: 35));
      while (true) {
        if (_disposed || ticket != _generation) return;
        snapshot = await engine.snapshot();
        if (_disposed || ticket != _generation) return;
        if (snapshot.firewall == 'reachable') break;
        if (!snapshot.running ||
            snapshot.firewall == 'blocked' ||
            now().isAfter(portDeadline)) {
          throw StateError('設定したポートの開放を確認できません。Wi-Fiとポート転送設定を確認してください');
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
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
      var lost = 0;
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
          if (!next.running || next.firewall != 'reachable') {
            await stop(message: 'ポート開放を確認できないため視聴・リレーを停止しました');
            return;
          }
          lost = next.playing || opening ? 0 : lost + 1;
          if (lost >= 15) {
            await stop(message: '配信との接続が終了しました');
            return;
          }
          if (now().difference(lastPortCheck).inSeconds >= 15) {
            lastPortCheck = now();
            await engine.checkPort(channel.tracker);
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
        if (snapshot.firewall != 'reachable') {
          throw StateError('ポート開放を確認できないため停止しました');
        }
        if (snapshot.playing) break;
        if (!snapshot.running) {
          throw StateError('視聴エンジンを開始できませんでした。待受ポートを確認してください');
        }
        if (now().isAfter(deadline)) {
          throw TimeoutException('配信に接続できませんでした');
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (_disposed || ticket != _generation) return;
      if (Platform.isAndroid) {
        final output = VideoPlayerController.networkUrl(uri);
        androidVideo = output;
        output.addListener(() {
          if (active && ticket == _generation && output.value.hasError) {
            unawaited(
              stop(message: '再生できませんでした: ${output.value.errorDescription}'),
            );
          }
        });
        await output.initialize().timeout(const Duration(seconds: 30));
        if (_disposed || ticket != _generation) return;
        await output.play();
      } else {
        simulatorAudioUnavailable = await _audioSession.activate();
        if (_disposed || ticket != _generation) return;
        final nativePlayer = player!.platform;
        if (nativePlayer is NativePlayer) {
          await nativePlayer.setProperty('cache-on-disk', 'no');
          if (simulatorAudioUnavailable) {
            // The bundled simulator libmpv has no audio output driver.
            // Explicit null output keeps video playing instead of emitting
            // a fatal-looking audio error. Never mute physical devices.
            await nativePlayer.setProperty('ao', 'null');
          }
        }
        if (_disposed || ticket != _generation) return;
        await player!
            .open(Media(uri.toString()))
            .timeout(const Duration(seconds: 30));
      }
      if (_disposed || ticket != _generation) return;
      opening = false;
      message = '視聴中';
      changed();
    } catch (e) {
      if (!_disposed && ticket == _generation) await stop(message: '$e');
    }
  }

  Future<void> stop({String message = '停止中'}) {
    ++_generation;
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
