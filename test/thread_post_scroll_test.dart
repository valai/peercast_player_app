import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/screens/thread_view.dart';
import 'package:peercast_app/services/board_resolver.dart';

import 'board_test.dart' as fixtures;

class PostingClient extends fixtures.FakeBoardClient {
  @override
  Future<void> post(
    BoardTarget target,
    String name,
    String mail,
    String message,
  ) async {
    count++;
    pending = Completer<void>();
  }
}

void main() {
  testWidgets('投稿後の取得待ちでもレス一覧を保持し追加分だけスクロールする', (tester) async {
    final client = PostingClient()..count = 50;
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadView(
            target: BoardResolver.resolve(
              'https://bbs.jpnkn.com/test/read.cgi/test/123/',
            )!,
            client: client,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('書き込み'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '投稿本文');
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    final position = controller.position;
    expect(position.extentAfter, closeTo(0, 1));
    await tester.tap(find.text('書き込む'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.position, same(position));
    expect(position.extentAfter, closeTo(0, 1));
    final before = controller.offset;
    client.pending!.complete();
    var previous = before;
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.position, same(position));
      expect(controller.offset, greaterThanOrEqualTo(previous - 1));
      previous = controller.offset;
    }
    expect(position.extentAfter, closeTo(0, 1));
    expect(find.byKey(const ValueKey(51)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
