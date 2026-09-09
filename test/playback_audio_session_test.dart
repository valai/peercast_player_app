import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/services/playback_audio_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('peercast_app/playback_audio');
  final calls = <String>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'iOS activates on each playback and releases only an acquired session',
    () async {
      final session = PlaybackAudioSession();
      await session.deactivate();
      await session.activate();
      await session.deactivate();
      await session.deactivate();
      await session.activate();
      await session.deactivate();
      expect(calls, ['activate', 'deactivate', 'activate', 'deactivate']);
    },
  );

  test(
    'activation failure reaches the caller without marking the session active',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            throw PlatformException(code: 'audio_session_activate_failed');
          });
      final session = PlaybackAudioSession();
      await expectLater(session.activate(), throwsA(isA<PlatformException>()));
      await session.deactivate();
      expect(calls, ['activate']);
    },
  );

  test('other platforms do not call the iOS channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final session = PlaybackAudioSession();
    expect(await session.activate(), isFalse);
    await session.deactivate();
    expect(calls, isEmpty);
  });

  test(
    'simulator requests silent output without acquiring a session',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return true;
          });
      final session = PlaybackAudioSession();
      expect(await session.activate(), isTrue);
      await session.deactivate();
      expect(calls, ['activate']);
    },
  );

  test('physical iOS devices keep audio enabled', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return false;
        });
    final session = PlaybackAudioSession();
    expect(await session.activate(), isFalse);
    await session.deactivate();
    expect(calls, ['activate', 'deactivate']);
  });
}
