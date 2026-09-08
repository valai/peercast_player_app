import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:peercast_app/services/board_client.dart';
import 'package:peercast_app/services/board_resolver.dart';
import 'package:peercast_app/screens/thread_view.dart';

class FakeBoardClient extends BoardClient {
  String? postedMail;
  int calls = 0;
  bool fail = false;
  int count = 1;
  @override
  Future<BoardThread> fetch(BoardTarget target) async {
    calls++;
    if (fail) throw Exception('offline');
    return BoardThread(
      'テストスレッド',
      List.generate(
        count,
        (i) => BoardPost(
          i + 1,
          '名無し',
          '今日',
          count == 1 ? '本文' : List.filled(i % 15 + 1, '本文').join('\n'),
        ),
      ),
    );
  }

  @override
  Future<void> post(
    BoardTarget target,
    String name,
    String mail,
    String message,
  ) async {
    postedMail = mail;
    throw Exception('送信失敗');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('投稿の宛先・フォームと成功判定、失敗時に自動再送しない', () async {
    const channel = MethodChannel('charset_converter');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final data = call.arguments['data'];
          if (call.method == 'encode') {
            return Uint8List.fromList(utf8.encode(data as String));
          }
          return utf8.decode(data as Uint8List);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    for (final url in [
      'https://bbs.jpnkn.com/test/read.cgi/test/123/',
      'https://jbbs.shitaraba.net/bbs/read.cgi/game/123/456/',
      'http://www.dmdbs.net/kizuna/test/read.cgi/sample/123456/',
    ]) {
      var calls = 0;
      final target = BoardResolver.resolve(url)!;
      final client = BoardClient(
        client: MockClient((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.headers['referer'], url);
          expect(request.bodyFields['MESSAGE'], '本文&追加');
          expect(request.url.path, switch (target.type) {
            BoardType.jpnkn => '/test/bbs.cgi',
            BoardType.dmdbs => '/kizuna/test/bbs.cgi',
            _ => '/bbs/write.cgi/game/123/456/',
          });
          if (target.type == BoardType.dmdbs) {
            expect(request.bodyFields['bbs'], 'sample');
            expect(request.bodyFields['key'], '123456');
            expect(request.bodyFields['url'], '');
            expect(request.bodyFields['password'], '');
          }
          return http.Response(
            calls == 1 ? '<title>書きこみました。</title>' : '<title>ERROR</title>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      );
      await client.post(target, '名前', 'sage', '本文&追加');
      await expectLater(
        client.post(target, '名前', 'sage', '本文&追加'),
        throwsException,
      );
      expect(calls, 2);
      client.dispose();
    }
  });
  final target = BoardResolver.resolve(
    'https://bbs.jpnkn.com/test/read.cgi/test/123/',
  )!;
  testWidgets('sage切り替え・投稿メール・フォーム外タップと下書き保持', (tester) async {
    final client = FakeBoardClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('フォーム外')),
          body: ThreadView(target: target, client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('書き込み'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'test@example.com');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, 'sage');
    expect(fields, findsNWidgets(3));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'test@example.com',
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.enterText(fields.last, '保存する下書き');
    await tester.ensureVisible(find.text('書き込む'));
    await tester.tap(find.text('書き込む'));
    await tester.pumpAndSettle();
    expect(client.postedMail, 'sage');
    await tester.tap(find.text('フォーム外'));
    await tester.pumpAndSettle();
    expect(fields, findsNothing);
    await tester.tap(find.byTooltip('書き込み'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(fields.last).controller!.text, '保存する下書き');
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    await tester.tap(find.byTooltip('書き込み'));
    await tester.pumpAndSettle();
    expect(fields, findsNothing);
    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });
  testWidgets('高さが異なる500レスで末尾へスクロールする', (tester) async {
    final client = FakeBoardClient()..count = 500;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadView(target: target, client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.controller!.position.extentAfter, lessThan(1));
    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });
  testWidgets('操作すると進行中の自動スクロールを繰り返さない', (tester) async {
    final client = FakeBoardClient()..count = 500;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadView(target: target, client: client),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final listFinder = find.byType(ListView);
    final controller = tester.widget<ListView>(listFinder).controller!;
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.position.extentAfter, greaterThan(1));
    final offset = controller.offset;
    await tester.pump(const Duration(seconds: 2));
    expect(controller.offset, offset);
    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });
  test('DMDBSの設置パスを保ってDATを取得する', () async {
    final target = BoardResolver.resolve(
      'https://www.dmdbs.net/kizuna/test/read.cgi/sample/123456/l50',
    )!;
    expect(target.type, BoardType.dmdbs);
    expect(target.isThread, isTrue);
    expect(target.uri.scheme, 'http');
    expect(
      BoardResolver.resolve(
        'https://www.dmdbs.net.evil.example/kizuna/test/read.cgi/sample/123456/',
      )!.type,
      BoardType.other,
    );
    expect(
      BoardResolver.resolve('https://www.dmdbs.net/other/')!.uri.scheme,
      'https',
    );
    final client = BoardClient(
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'http://www.dmdbs.net/kizuna/sample/dat/123456.dat',
        );
        return http.Response(
          '名前<>sage<>日時<>本文<br>続き<>題名',
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
    );
    final result = await client.fetch(target);
    expect(result.title, '題名');
    expect(result.posts.single.body, '本文\n続き'.replaceAll(r'\n', '\n'));
    client.dispose();
  });
  test('同じ応答は再利用し、同じレス数でも本文の変更を反映する', () async {
    var body = List.generate(
      1000,
      (i) => '名前<>sage<>日時<>本文$i<br>&lt;例&gt;<>題名',
    ).join('\n');
    final client = BoardClient(
      client: MockClient(
        (_) async => http.Response(
          body,
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        ),
      ),
    );
    addTearDown(client.dispose);
    final first = await client.fetch(target);
    expect(first.posts.length, 1000);
    expect(first.posts.last.body, '本文999\n<例>');
    expect(identical(await client.fetch(target), first), isTrue);
    body = body.replaceAll('本文999', '削除済み');
    final changed = await client.fetch(target);
    expect(identical(changed, first), isFalse);
    expect(changed.posts.last.body, '削除済み\n<例>');
  });
  test('DATの改行・HTML・エンティティを解析', () {
    final value = BoardClient.parse(
      '名無し<>sage<>日付<>一行<br>二行 &lt;例&gt;<>題名\n削除<><>日付<>あぼーん<>',
      BoardType.jpnkn,
    );
    expect(value.title, '題名');
    expect(value.posts.first.body, '一行\n二行 <例>');
    expect(value.posts.last.number, 2);
  });
  test('したらばの欠番を保持する', () {
    final value = BoardClient.parse(
      '1<>名前<>sage<>日付<>本文<>題名<>ID\n3<>名前<><>日付<>続き<><>ID',
      BoardType.shitaraba,
    );
    expect(value.posts.map((p) => p.number), [1, 3]);
  });
  test('HTMLエラーをレスと扱わない', () {
    expect(
      () => BoardClient.parse('<html>error</html>', BoardType.jpnkn),
      throwsFormatException,
    );
  });
  test('DAT取得先とHTTPエラー', () async {
    final client = BoardClient(
      client: MockClient((request) async {
        expect(request.url.path, '/test/dat/123.dat');
        return http.Response('unavailable', 503);
      }),
    );
    await expectLater(client.fetch(target), throwsException);
    client.dispose();
  });
  testWidgets('自動更新・OFF・失敗時のレスと下書き保持・終了時のタイマー停止', (tester) async {
    final client = FakeBoardClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadView(target: target, client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本文'), findsOneWidget);
    expect(client.calls, 1);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(client.calls, 2);
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OFF').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 60));
    expect(client.calls, 2);
    client.fail = true;
    await tester.tap(find.byTooltip('更新'));
    await tester.pumpAndSettle();
    expect(find.text('本文'), findsOneWidget);
    await tester.tap(find.byTooltip('書き込み'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '下書き');
    await tester.ensureVisible(find.text('書き込む'));
    await tester.tap(find.text('書き込む'));
    await tester.pumpAndSettle();
    expect(find.text('下書き'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 60));
    expect(tester.takeException(), isNull);
    client.dispose();
  });
}
