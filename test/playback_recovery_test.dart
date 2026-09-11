import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:peercast_app/models/channel.dart';
import 'package:peercast_app/services/app_settings.dart';
import 'package:peercast_app/services/peercast_engine.dart';
import 'package:peercast_app/services/playback_controller.dart';

import 'playback_policy_test.dart' show FakeEngine;

class PlayingEngine extends FakeEngine {
  @override
  Future<EngineSnapshot> snapshot() async =>
      EngineSnapshot(running: running, playing: running, firewall: 'reachable');
}

class FakeVideo extends VideoPlayerController {
  FakeVideo(super.uri, {this.fail = false}) : super.networkUrl();
  final bool fail;
  bool disposed = false;
  double? volume;
  @override
  Future<void> initialize() async {
    if (fail) throw StateError('decoder failed');
    value = const VideoPlayerValue(
      duration: Duration.zero,
      isInitialized: true,
    );
  }

  void crash() =>
      value = VideoPlayerValue.erroneous('Unexpected runtime error');
  @override
  Future<void> play() async {}
  @override
  Future<void> setVolume(double volume) async {
    this.volume = volume;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'recover',
    'fail',
    'stop',
    'wifi',
    'repeated',
    'switch',
  ]) {
    testWidgets('Android recovery: $scenario', (tester) async {
      SharedPreferences.setMockInitialValues({});
      late AppSettings settings;
      await tester.runAsync(() async {
        settings = await AppSettings.load();
      });
      final engine = PlayingEngine();
      final videos = <FakeVideo>[];
      final changes = StreamController<List<ConnectivityResult>>();
      final controller = PlaybackController(
        settings: settings,
        engine: engine,
        emulatorCheck: () async => true,
        now: tester.binding.clock.now,
        connectivityCheck: () async => [ConnectivityResult.wifi],
        connectivityChanges: changes.stream,
        supportDirectory: () async => Directory('.'),
        playerFactory: () => null,
        androidVideoFactory: (uri) {
          final video = FakeVideo(
            uri,
            fail: scenario == 'fail' && videos.isNotEmpty,
          );
          videos.add(video);
          return video;
        },
      );
      final fields = List.filled(19, '');
      fields[0] = 'test';
      fields[1] = '0123456789ABCDEF0123456789ABCDEF';
      fields[2] = '127.0.0.1:7144';
      fields[9] = 'FLV';
      final channel = Channel.parse(
        fields.join('<>'),
        YellowPage.defaults.first,
      ).single;
      await controller.start(channel);
      await controller.toggleMute();
      videos.first.crash();
      videos.first.crash();
      expect(controller.active, true);
      expect(controller.opening, true);
      expect(engine.running, true);
      if (scenario == 'stop' || scenario == 'wifi' || scenario == 'switch') {
        if (scenario == 'wifi') {
          changes.add([ConnectivityResult.mobile]);
          await tester.pump();
        } else if (scenario == 'switch') {
          await controller.start(channel);
        } else {
          await controller.stop();
        }
        await tester.pump(const Duration(seconds: 10));
        expect(videos.length, scenario == 'switch' ? 2 : 1);
        expect(controller.active, scenario == 'switch');
      } else if (scenario == 'fail' || scenario == 'repeated') {
        for (var attempt = 1; attempt <= 3; attempt++) {
          await tester.pump(Duration(seconds: attempt));
          if (scenario == 'repeated') videos.last.crash();
        }
        await tester.pump();
        expect(videos.length, 4);
        expect(controller.active, false);
        expect(engine.running, false);
        expect(controller.message, contains('再生を復旧できませんでした'));
      } else {
        await tester.pump(const Duration(seconds: 1));
        expect(videos.length, 2);
        expect(videos.first.disposed, true);
        expect(videos.last.volume, 0);
        expect(controller.active, true);
        expect(controller.opening, false);
        expect(engine.starts, 1);
        expect(engine.connects, 1);
        await tester.pump(const Duration(seconds: 4));
        expect(videos.length, 2);
        // Stable playback replenishes the retry budget.
        await tester.pump(const Duration(minutes: 2));
        videos.last.crash();
        await tester.pump(const Duration(seconds: 1));
        expect(videos.length, 3);
      }
      await controller.stop();
      controller.dispose();
      await tester.pump();
      unawaited(changes.close());
    });
  }
}
