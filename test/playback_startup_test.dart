import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/services/playback_startup.dart';

void main() {
  testWidgets('open完了だけでは成功にせず、進行しない配信をタイムアウトする', (tester) async {
    final positions = StreamController<Duration>();
    final startup = PlaybackStartup(positions.stream);
    final result = expectLater(startup.ready, throwsA(isA<TimeoutException>()));
    positions.add(Duration.zero);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    await result;
    expect(positions.hasListener, false);
    unawaited(positions.close());
    await tester.pump();
  });

  testWidgets('映像フレームに依存せず音声のみでも再生進行で成功する', (tester) async {
    final positions = StreamController<Duration>();
    final startup = PlaybackStartup(positions.stream);
    positions.add(const Duration(milliseconds: 100));
    await tester.pump();
    expect(await startup.ready, true);
    expect(positions.hasListener, false);
    await tester.pump(const Duration(seconds: 31));
    unawaited(positions.close());
    await tester.pump();
  });

  testWidgets('停止時に待機とタイマーを解除し、次の再生に影響しない', (tester) async {
    final positions = StreamController<Duration>();
    final first = PlaybackStartup(positions.stream);
    first.cancel();
    expect(await first.ready, false);
    await tester.pump(const Duration(seconds: 31));
    expect(positions.hasListener, false);
    unawaited(positions.close());
    await tester.pump();
  });
}
