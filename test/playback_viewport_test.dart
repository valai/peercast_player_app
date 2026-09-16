import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/screens/playback_overlay.dart';
import 'package:peercast_app/screens/playback_viewport.dart';

void main() {
  testWidgets('下スワイプだけで小窓化し、タップとボタンは従来どおり動く', (tester) async {
    var minimized = 0, buttons = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: PlaybackOverlay(
              top: const Text('詳細'),
              bottom: TextButton(
                onPressed: () => buttons++,
                child: const Text('ボタン'),
              ),
              child: PlaybackViewport(
                onSwipeDown: () => minimized++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(PlaybackViewport));
    await tester.dragFrom(center, const Offset(0, 80));
    expect(minimized, 1);
    await tester.dragFrom(center, const Offset(90, 70));
    await tester.dragFrom(center, const Offset(0, -80));
    await tester.dragFrom(center, const Offset(0, 30));
    expect(minimized, 1);
    await tester.tap(find.text('ボタン'));
    expect(buttons, 1);
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
          .opacity,
      0,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ピンチを1〜4倍に制限し、PiP復帰後に拡大状態を戻す', (tester) async {
    var minimized = 0;
    final key = GlobalKey();
    Future<void> show(bool pip) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: PlaybackViewport(
              key: key,
              inPip: pip,
              onSwipeDown: () => minimized++,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    double scale() => tester
        .widget<Transform>(
          find.descendant(
            of: find.byType(PlaybackViewport),
            matching: find.byType(Transform),
          ),
        )
        .transform
        .entry(0, 0);
    Future<void> pinch(double from, double to, {double pan = 0}) async {
      final center = tester.getCenter(find.byType(PlaybackViewport));
      final a = await tester.startGesture(center - Offset(from, 0), pointer: 1);
      final b = await tester.startGesture(center + Offset(from, 0), pointer: 2);
      await tester.pump();
      await a.moveTo(center - Offset(to, -pan));
      await b.moveTo(center + Offset(to, pan));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pump();
    }

    await show(false);
    await pinch(10, 180, pan: 90);
    expect(scale(), 4);
    expect(minimized, 0);
    await show(true);
    expect(scale(), 1);
    await show(false);
    expect(scale(), 4);
    await pinch(180, 1);
    expect(scale(), 1);
    final transform = tester
        .widget<Transform>(
          find.descendant(
            of: find.byType(PlaybackViewport),
            matching: find.byType(Transform),
          ),
        )
        .transform;
    expect(transform.entry(0, 3), 0);
    expect(transform.entry(1, 3), 0);
    expect(minimized, 0);
  });
}
