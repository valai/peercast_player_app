import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/services/playback_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('peercast/playback');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late PlaybackBackground bridge;

  Future<void> event(String name, [Object? value]) async {
    final complete = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(name, value)),
      (_) => complete.complete(),
    );
    await complete.future;
  }

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'pipSupported' || 'start' || 'enterPip' => true,
        _ => null,
      };
    });
    bridge = PlaybackBackground(android: true);
  });
  tearDown(() {
    bridge.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('サービス起動前・停止後は自動PiPを有効にしない', () async {
    await bridge.configure(playing: true);
    expect((calls.last.arguments as Map)['playing'], false);
    await bridge.start('チャンネル');
    await bridge.configure(playing: true, aspectRatio: 4 / 3);
    expect((calls.last.arguments as Map)['playing'], true);
    expect(await bridge.enterPip(), true);
    await bridge.stop();
    await bridge.configure(playing: true);
    expect((calls.last.arguments as Map)['playing'], false);
    expect(await bridge.enterPip(), false);
  });

  test('サービス稼働中はロック・バックグラウンドで継続し、切り離し時は停止', () async {
    expect(bridge.shouldStopForLifecycle(AppLifecycleState.paused), true);
    expect(bridge.shouldStopForLifecycle(AppLifecycleState.inactive), false);
    await bridge.start('test');
    expect(bridge.shouldStopForLifecycle(AppLifecycleState.hidden), false);
    expect(bridge.shouldStopForLifecycle(AppLifecycleState.paused), false);
    expect(bridge.shouldStopForLifecycle(AppLifecycleState.detached), true);
    await bridge.stop();
    expect(bridge.shouldStopForLifecycle(AppLifecycleState.hidden), true);
  });

  test('起動失敗時はバックグラウンド継続とPiPを許可しない', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') throw PlatformException(code: 'denied');
      return true;
    });
    await bridge.start('test');
    expect(bridge.running, false);
    expect(bridge.notice, isNotNull);
    expect(await bridge.enterPip(), false);
  });

  test('起動中に停止した場合、遅い成功応答で継続を再許可しない', () async {
    final result = Completer<bool>();
    final requested = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        requested.complete();
        return result.future;
      }
      return call.method == 'pipSupported' ? true : null;
    });
    final start = bridge.start('test');
    await requested.future;
    await bridge.stop();
    result.complete(true);
    await start;
    expect(bridge.running, false);
  });

  test('PiP復帰は停止せず、閉鎖要求とサービス障害で停止する', () async {
    var stops = 0;
    bridge.onStop = () => stops++;
    await bridge.start('test');
    await event('pipChanged', true);
    expect(bridge.inPip, true);
    await event('pipChanged', false);
    expect(stops, 0);
    await event('pipFailed');
    expect(bridge.notice, contains('PiP'));
    await event('stop');
    expect(stops, 1);
    await event('serviceLost');
    expect(stops, 2);
    expect(bridge.running, false);
  });

  test('古いセッションの破棄が新しいセッションの通知を解除しない', () async {
    final old = bridge;
    bridge = PlaybackBackground(android: true);
    old.dispose();
    await event('pipChanged', true);
    expect(bridge.inPip, true);
  });

  test('Android以外ではサービスを起動しない', () async {
    final other = PlaybackBackground(android: false);
    await other.start('test');
    await other.configure(playing: true);
    await other.stop();
    expect(calls, isEmpty);
    expect(other.running, false);
    other.dispose();
  });
}
