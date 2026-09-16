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
  Channel? checkedChannel;
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
  Future<void> checkPort(Channel channel) async {
    checkedChannel = channel;
    checks++;
  }

  @override
  Future<EngineSnapshot> snapshot() async => EngineSnapshot(
    running: running,
    firewall: firewall,
    portCheckError: firewall == 'blocked' ? '確認先から逆接続できないと応答されました' : '',
  );
  @override
  Future<void> stop() async {
    running = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('ポート確認の診断を読み込み、旧形式にも対応する', () {
    expect(
      EngineSnapshot.fromJson({'portCheckError': '確認先との通信失敗'}).portCheckError,
      '確認先との通信失敗',
    );
    expect(EngineSnapshot.fromJson({}).portCheckError, isEmpty);
  });
  test('受信タイムアウトに接続段階とコアのエラーを表示する', () {
    final snapshot = EngineSnapshot.fromJson({
      'status': 'CONNECT',
      'connectionError': 'PCP readPacket: Read failed (1008)',
    });
    expect(snapshot.connectionTimeoutMessage, contains('中継先と接続処理中'));
    expect(snapshot.connectionTimeoutMessage, contains('Read failed (1008)'));
    expect(
      const EngineSnapshot(status: 'SEARCH').connectionTimeoutMessage,
      contains('中継先を探索中'),
    );
    expect(EngineSnapshot.fromJson({}).connectionError, isEmpty);
    expect(
      const EngineSnapshot().connectionTimeoutMessage,
      isNot(contains('配信が終了しました')),
    );
  });
  test('PCP 1003は配信終了ではなくリレー受付不可として案内する', () {
    const snapshot = EngineSnapshot(
      status: 'SEARCH',
      connectionError: 'PCP readPacket: PCP exception (1003)',
    );
    expect(snapshot.connectionTimeoutMessage, contains('リレー受付不可'));
    expect(snapshot.connectionTimeoutMessage, isNot(contains('配信終了')));
  });
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
    'emulatorBlocked',
    'emulatorUnknown',
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
        emulatorCheck: () async => scenario.startsWith("emulator"),
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
      if (scenario == 'blocked' || scenario == 'emulatorBlocked') {
        engine.firewall = 'blocked';
      }
      if (scenario == 'lostPort' || scenario == 'lostWifi') {
        engine.firewall = 'reachable';
      }
      final starting = controller.start(channel);
      await tester.pump();
      if (scenario != 'mobile' && !scenario.startsWith('emulator')) {
        expect(engine.checkedChannel, same(channel));
      }
      if (scenario.startsWith('emulator')) {
        expect(engine.connects, 1);
        expect(engine.checks, 0);
        expect(controller.active, true);
        await tester.pump(const Duration(seconds: 16));
        expect(controller.active, true);
        expect(engine.checks, 0);
        engine.running = false;
        await tester.pump(const Duration(seconds: 1));
        expect(controller.active, false);
      } else if (scenario == 'mobile') {
        expect(engine.starts, 0);
        expect(controller.active, false);
      } else if (scenario == 'blocked') {
        expect(controller.message, contains('7145'));
        expect(controller.message, contains('逆接続できない'));
        expect(controller.message, isNot(contains('Bad state')));
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
          expect(engine.checks, 1);
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
