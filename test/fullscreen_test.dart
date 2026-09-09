import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/services/fullscreen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const display = MethodChannel('peercast/display');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(display, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('Androidチャンネルで全画面の開始と終了を通知する', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(display, (call) async {
      calls.add(call);
      return null;
    });
    await setPlaybackFullscreen(true);
    await setPlaybackFullscreen(false);
    expect(calls.map((call) => call.method), [
      'setFullscreen',
      'setFullscreen',
    ]);
    expect(calls.map((call) => call.arguments), [true, false]);
  });

  test('ネイティブ未登録でも例外を漏らさず標準UI制御へ切り替える', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    await setPlaybackFullscreen(true);
    await setPlaybackFullscreen(false);
    expect(calls.map((call) => call.arguments), [
      'SystemUiMode.immersiveSticky',
      'SystemUiMode.edgeToEdge',
    ]);
  });
}
