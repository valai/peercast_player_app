import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/screens/playback_overlay.dart';

void main() {
  testWidgets('5秒で自動非表示、画面タップで切り替え、操作ボタンは表示を維持する', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackOverlay(
            top: const Text('詳細・コメント / 視聴者数: 10人'),
            bottom: TextButton(
              onPressed: () => presses++,
              child: const Text('操作'),
            ),
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    final panels = find.byType(AnimatedOpacity);
    void expectOpacity(double value) {
      for (final panel in tester.widgetList<AnimatedOpacity>(panels)) {
        expect(panel.opacity, value);
      }
    }

    expectOpacity(1);
    await tester.pump(const Duration(seconds: 4));
    expectOpacity(1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 200));
    expectOpacity(0);
    await tester.tapAt(tester.getCenter(find.text('操作')));
    await tester.pump();
    expect(presses, 0);
    expectOpacity(1);
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('操作'));
    await tester.pump();
    expect(presses, 1);
    await tester.pump(const Duration(seconds: 4));
    expectOpacity(1);
    await tester.pump(const Duration(seconds: 1));
    expectOpacity(0);
    final screenCenter = tester.getCenter(find.byType(PlaybackOverlay));
    await tester.tapAt(screenCenter);
    await tester.pumpAndSettle();
    expectOpacity(1);
    await tester.tapAt(screenCenter);
    await tester.pump();
    expectOpacity(0);
    for (final fade in tester.widgetList<FadeTransition>(
      find.descendant(of: panels, matching: find.byType(FadeTransition)),
    )) {
      expect(fade.opacity.value, 0);
    }
    await tester.pump(const Duration(seconds: 2));
    await tester.tapAt(screenCenter);
    await tester.pump();
    expectOpacity(1);
    await tester.pump(const Duration(seconds: 4));
    expectOpacity(1);
    await tester.pump(const Duration(seconds: 1));
    expectOpacity(0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('上下の背景は再生領域の左右端まで広がる', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 180,
            child: PlaybackOverlay(
              top: Text('チャンネル詳細'),
              bottom: Text('操作'),
              child: ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    final area = tester.getRect(find.byType(PlaybackOverlay));
    for (final panel in find.byType(AnimatedOpacity).evaluate()) {
      final rect = tester.getRect(find.byWidget(panel.widget));
      expect(rect.left, area.left);
      expect(rect.right, area.right);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
