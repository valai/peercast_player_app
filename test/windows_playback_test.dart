import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/models/channel.dart';
import 'package:peercast_app/services/app_settings.dart';
import 'package:peercast_app/services/peercast_engine.dart';
import 'package:peercast_app/services/playback_background.dart';
import 'package:peercast_app/services/playback_controller.dart';
import 'package:peercast_app/services/windows_mobile_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const channel = Channel(
  id: '0123456789ABCDEF0123456789ABCDEF',
  name: 'test',
  sourceId: 'sp',
  sourceName: 'SP',
  tracker: 'example.net:7144',
  contact: '',
  genre: '',
  description: '',
  comment: '',
  format: 'FLV',
  bitrate: 500,
  listeners: 1,
);

class FakeStore extends WindowsCredentialStore {
  final credentials = WindowsCredentials(
    Uri.parse('http://100.101.102.103:17444'),
    'secret',
  );
  @override
  Future<WindowsCredentials?> read() async => credentials;
  @override
  Future<void> delete() async {}
}

class FakeWindowsApi extends WindowsMobileApi {
  FakeWindowsApi(
    super.credentials, {
    required this.conflict,
    this.statusSessionId = 'session',
  });
  final bool conflict;
  final String statusSessionId;
  int starts = 0, stops = 0;

  @override
  Future<String> start(Channel channel) async {
    starts++;
    if (conflict && starts == 1) {
      throw const WindowsApiException('busy', statusCode: 409);
    }
    return 'session';
  }

  @override
  Future<WindowsSessionStatus> status() async => WindowsSessionStatus(
    sessionId: statusSessionId,
    channelId: '0123456789ABCDEF0123456789ABCDEF',
    state: 'failed',
    error: '変換できません',
    peerCastOnline: true,
    relayReachable: false,
    downstreamRelays: 0,
    relayMessage: '',
    playlists: {},
  );

  @override
  Future<void> stop() async {
    stops++;
  }
}

class FakeEngine implements EngineBackend {
  int starts = 0;
  @override
  Future<Uri> start(
    Channel channel,
    String directory,
    int port,
    int relays,
  ) async {
    starts++;
    return Uri.parse('http://127.0.0.1/test.flv');
  }

  @override
  Future<void> connect(Channel channel) async {}
  @override
  Future<void> checkPort(Channel channel) async {}
  @override
  Future<EngineSnapshot> snapshot() async => const EngineSnapshot();
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final replace in [false, true]) {
    test('Windowsの競合確認=$replace、端末リレーを起動しない', () async {
      final settings = await AppSettings.load();
      settings.playbackSource = PlaybackSource.windows;
      final api = FakeWindowsApi(FakeStore().credentials, conflict: true);
      final engine = FakeEngine();
      final connectivity = StreamController<List<ConnectivityResult>>();
      final controller = PlaybackController(
        settings: settings,
        engine: engine,
        credentialStore: FakeStore(),
        windowsApiFactory: (_) => api,
        confirmWindowsSwitch: () async => replace,
        connectivityChanges: connectivity.stream,
        playerFactory: () => null,
        supportDirectory: () async => Directory('.'),
        background: PlaybackBackground(android: false),
      );
      await controller.start(channel);
      expect(engine.starts, 0);
      expect(api.starts, replace ? 2 : 1);
      expect(api.stops, replace ? 2 : 0);
      expect(controller.active, false);
      expect(controller.message, contains(replace ? '変換できません' : '別の番組'));
      controller.dispose();
      await connectivity.close();
    });
  }

  test('Windows側のセッションが切り替わっても新しい番組は停止しない', () async {
    final settings = await AppSettings.load();
    settings.playbackSource = PlaybackSource.windows;
    final api = FakeWindowsApi(
      FakeStore().credentials,
      conflict: false,
      statusSessionId: 'other',
    );
    final connectivity = StreamController<List<ConnectivityResult>>();
    final controller = PlaybackController(
      settings: settings,
      engine: FakeEngine(),
      credentialStore: FakeStore(),
      windowsApiFactory: (_) => api,
      connectivityChanges: connectivity.stream,
      playerFactory: () => null,
      background: PlaybackBackground(android: false),
    );
    await controller.start(channel);
    expect(api.stops, 0);
    expect(controller.message, contains('切り替わりました'));
    controller.dispose();
    await connectivity.close();
  });
}
