import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:peercast_app/models/channel.dart';
import 'package:peercast_app/screens/watch_screen.dart';
import 'package:peercast_app/services/app_settings.dart';
import 'package:peercast_app/services/playback_background.dart';
import 'package:peercast_app/services/playback_controller.dart';
import 'package:peercast_app/services/peercast_engine.dart';

import 'playback_recovery_test.dart' show FakeVideo, PlayingEngine;

class RelayEngine extends PlayingEngine {
  bool listening = true;
  @override
  Future<EngineSnapshot> snapshot() async => EngineSnapshot(
    running: running,
    playing: running,
    listening: listening,
    firewall: 'reachable',
    relays: 0,
  );
}

class Background extends PlaybackBackground {
  Background() : super(android: false);
  @override
  Future<void> start(String title) async {
    running = true;
  }

  void setPip(bool value) {
    inPip = value;
    notifyListeners();
  }
}

void main() {
  testWidgets('一覧への小窓化・復帰でプレイヤーとリレー接続を作り直さない', (tester) async {
    final orientations = <List<dynamic>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        orientations.add(List<dynamic>.from(call.arguments as List));
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    SharedPreferences.setMockInitialValues({});
    late AppSettings settings;
    await tester.runAsync(() async {
      settings = await AppSettings.load();
    });
    final engine = RelayEngine();
    final links = StreamController<List<ConnectivityResult>>();
    final videos = <FakeVideo>[];
    final background = Background();
    final controller = PlaybackController(
      settings: settings,
      engine: engine,
      background: background,
      emulatorCheck: () async => true,
      connectivityCheck: () async => [ConnectivityResult.wifi],
      connectivityChanges: links.stream,
      supportDirectory: () async => Directory('.'),
      playerFactory: () => null,
      androidVideoFactory: (uri) {
        final video = FakeVideo(uri);
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
    var small = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Stack(
              children: [
                const Positioned.fill(child: Scaffold(body: Text('一覧'))),
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: small ? 220 : 800,
                  height: small ? 124 : 600,
                  child: WatchScreen(
                    channel: channel,
                    settings: settings,
                    controller: controller,
                    minimized: small,
                    onMinimize: () => update(() => small = true),
                    onRestore: () => update(() => small = false),
                    onClose: () {},
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(controller.active, true);
    expect(videos, hasLength(1));
    expect(orientations.last, contains('DeviceOrientation.landscapeLeft'));
    await tester.tap(find.byTooltip('ミニプレイヤーでチャンネル一覧へ'));
    await tester.pump();
    expect(small, true);
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
    expect(tester.takeException(), isNull);
    expect(videos, hasLength(1));
    expect(videos.single.disposed, false);
    expect(engine.connects, 1);
    await tester.tap(find.byTooltip('再生画面に戻る'));
    await tester.pump();
    expect(small, false);
    expect(
      orientations.last,
      containsAll([
        'DeviceOrientation.portraitUp',
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]),
    );
    expect(engine.starts, 1);
    expect(tester.takeException(), isNull);
    // Expand OS PiP back into the existing watch screen, including when it
    // was launched from the in-app mini player. A slow resume must not restart.
    for (final fromMini in [false, true]) {
      update(() => small = fromMini);
      await tester.pump();
      background.setPip(true);
      await tester.pump();
      background.setPip(false);
      await tester.pump(const Duration(seconds: 2));
      expect(small, false);
      expect(controller.active, true);
      expect(background.running, true);
      expect(videos, hasLength(1));
      expect(videos.single.disposed, false);
      expect(engine.starts, 1);
      expect(engine.connects, 1);
      expect(find.byTooltip('ミニプレイヤーでチャンネル一覧へ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    // Zero downstream clients is healthy. Losing the listening socket is not.
    await tester.pump(const Duration(seconds: 1));
    expect(controller.active, true);
    engine.listening = false;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.active, false);
    expect(engine.running, false);
    expect(controller.background.running, false);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    unawaited(links.close());
  });
}
