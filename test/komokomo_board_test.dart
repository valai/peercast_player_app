import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:peercast_app/screens/thread_view.dart';
import 'package:peercast_app/services/board_client.dart';
import 'package:peercast_app/services/board_resolver.dart';

import 'board_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'https://komokomo.ddns.net/test/read.cgi/dokkoimigu/1789427174/';

  test('こもこものスレッドと掲示板トップを認識しHTTPSを維持する', () {
    for (final suffix in ['', 'l50', '1-100']) {
      final target = BoardResolver.resolve('$url$suffix')!;
      expect(target.type, BoardType.komokomo);
      expect(target.isThread, isTrue);
      expect(target.threadKey, '1789427174');
      expect(
        target.boardUri.toString(),
        'https://komokomo.ddns.net/dokkoimigu/',
      );
      expect(target.threadTarget('1789427174').uri.toString(), url);
      final home = BoardResolver.resolve(target.boardUri.toString())!;
      expect(home.type, BoardType.komokomo);
      expect(home.isThread, isFalse);
    }
    expect(
      BoardResolver.resolve(
        'https://komokomo.ddns.net.evil.example/test/read.cgi/dokkoimigu/1789427174/',
      )!.type,
      BoardType.other,
    );
  });

  test('charset指定のないDATとsubjectをCP932で読み込む', () async {
    const channel = MethodChannel('charset_converter');
    const dat =
        '自動新スレ立て ★<><>2026/09/15(火) 08:06:14 ID:NewThread<>本文<br>続き<>みぐみぐ避難所 【part176】\n'
        '避難所民<>sage<>2026/09/15(火) 08:35:25.46<> test <>\n';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.arguments['charset'], 'cp932');
          final data = call.arguments['data'] as Uint8List;
          return data.first == 1
              ? dat
              : '1789427174.dat<>みぐみぐ避難所 【part176】 (2)\n';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final client = BoardClient(
      client: MockClient((request) async {
        expect(request.url.scheme, 'https');
        expect(request.url.host, 'komokomo.ddns.net');
        if (request.url.path == '/dokkoimigu/dat/1789427174.dat') {
          return http.Response.bytes([1], 200);
        }
        expect(request.url.path, '/dokkoimigu/subject.txt');
        return http.Response.bytes([2], 200);
      }),
    );
    addTearDown(client.dispose);
    final target = BoardResolver.resolve(url)!;
    final thread = await client.fetch(target);
    expect(thread.title, 'みぐみぐ避難所 【part176】');
    expect(thread.posts.length, 2);
    expect(thread.posts.first.body, '本文\n続き');
    expect(thread.posts.last.number, 2);
    expect(thread.posts.last.mail, 'sage');
    final entries = await client.fetchThreads(target);
    expect(entries.single.target.uri.toString(), url);
    expect(entries.single.count, 2);
  });

  testWidgets('対象URLをアプリ内のレス表示に渡せる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadView(
            target: BoardResolver.resolve(url)!,
            client: fixtures.FakeBoardClient(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('テストスレッド'), findsOneWidget);
    expect(find.textContaining('本文'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
