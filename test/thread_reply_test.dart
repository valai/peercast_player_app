import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/screens/thread_view.dart';
import 'package:peercast_app/services/board_resolver.dart';

import 'board_test.dart' as fixtures;

void main() {
  testWidgets('レス番号からキャンセル、返信、下書きを保持して引用を挿入', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadView(
            target: BoardResolver.resolve(
              'https://jbbs.shitaraba.net/bbs/read.cgi/game/123/456/',
            )!,
            client: fixtures.FakeBoardClient()..count = 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reply-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '本文'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reply-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返信'));
    await tester.pumpAndSettle();
    final body = find.widgetWithText(TextField, '本文');
    expect(tester.widget<TextField>(body).controller!.text, '>>1\n');
    expect(tester.widget<TextField>(body).controller!.selection.baseOffset, 4);
    await tester.enterText(body, '下書き');
    await tester.tap(find.byTooltip('書き込み'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reply-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返信'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(body).controller!.text, '>>1\n下書き');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
