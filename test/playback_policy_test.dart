import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:peercast_app/models/channel.dart';
import 'package:peercast_app/services/app_settings.dart';
import 'package:peercast_app/services/peercast_engine.dart';
import 'package:peercast_app/services/playback_controller.dart';

class FakeEngine implements EngineBackend {
  int starts = 0, connects = 0, checks = 0;
  bool running = false;
  String firewall = 'unknown';
  @override
  Future<Uri> start(
    Channel channel,
    String directory,
    int port,
    int relays,
  ) async {
    starts++;
    running = true;
    expectSync(relays, greaterThanOrEqualTo(1));
    return Uri.parse('http://127.0.0.1:$port/stream/test.flv');
  }

  @override
  Future<void> connect(Channel channel) async {
    connects++;
  }

  @override
  Future<void> checkPort(String tracker) async {
    checks++;
  }

  @override
  Future<EngineSnapshot> snapshot() async =>
      EngineSnapshot(running: running, firewall: firewall);
  @override
  Future<void> stop() async {
    running = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('旧設定のWi-Fi無効・リレー0を移行する', () async {
    await AppSettings.load();
    final prefs = await SharedPreferences.getInstance();
    final old = jsonDecode(
      prefs.getString(AppSettings.storageKey)!,
    ) as Map<String, dynamic>;
    old['wifiOnly'] = false;
    old['maxRelays'] = 0;
    await prefs.setString(AppSettings.storageKey, jsonEncode(old));
    final settings = await AppSettings.load();
    expect(settings.maxRelays, 1);
    settings.maxRelays = 0;
    expect(settings.maxRelays, 1);
    await settings.save();
    expect(
      jsonDecode(prefs.getString(AppSettings.storageKey)!),
      isNot(contains('wifiOnly')),
    );
  });
  for (final scenario in [
    'mobile',
    'blocked',
    'unknown',
    'lostPort',
    'lostWifi',
    'cancel',
  ]) {
    testWidgets('再生・リレー開始条件: $scenario', (tester) async {
      late AppSettings settings;
      await tester.runAsync(() async {
        settings = await AppSettings.load();
      });
      final engine = FakeEngine();
      var links = [
        scenario == 'mobile'
            ? ConnectivityResult.mobile
            : ConnectivityResult.wifi,
      ];
      final changes = StreamController<List<ConnectivityResult>>();
      final controller = PlaybackController(
        settings: settings,
        now: tester.binding.clock.now,
        engine: engine,
        connectivityCheck: () async => links,
        connectivityChanges: changes.stream,
        supportDirectory: () async => Directory('.'),
        playerFactory: () => null,
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
      if (scenario == 'blocked') engine.firewall = 'blocked';
      if (scenario == 'lostPort' || scenario == 'lostWifi') {
        engine.firewall = 'reachable';
      }
      final starting = controller.start(channel);
      await tester.pump();
      if (scenario == 'mobile') {
        expect(engine.starts, 0);
        expect(controller.active, false);
      } else if (scenario == 'blocked') {
        expect(engine.checks, 1);
        expect(engine.connects, 0);
        expect(controller.active, false);
      } else if (scenario == 'unknown') {
        expect(engine.checks, 1);
        expect(controller.active, true);
        expect(engine.connects, 0);
        await tester.pump(const Duration(seconds: 36));
        expect(controller.active, false);
      } else if (scenario == 'cancel') {
        await controller.stop();
        engine.firewall = 'reachable';
        await tester.pump(const Duration(seconds: 1));
        expect(engine.connects, 0);
      } else {
        expect(engine.connects, 1, reason: controller.message);
        if (scenario == 'lostPort') {
          await tester.pump(const Duration(seconds: 15));
          expect(engine.checks, 2);
          engine.firewall = 'unknown';
        } else {
          links = [ConnectivityResult.mobile];
          changes.add(links);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(controller.active, false);
        expect(engine.running, false);
      }
      await tester.pump(const Duration(seconds: 1));
      await starting;
      controller.dispose();
      await tester.pump();
      unawaited(changes.close());
      await tester.pump();
    });
  }
}
