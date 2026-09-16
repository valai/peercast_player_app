import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:peercast_app/main.dart';
import 'package:peercast_app/services/app_settings.dart';
import 'package:peercast_app/services/channel_directory.dart';
import 'package:peercast_app/services/board_client.dart';
import 'package:peercast_app/services/board_resolver.dart';
import 'package:peercast_app/screens/thread_view.dart';
import 'package:peercast_app/screens/thread_list_view.dart';

import 'board_test.dart' as fixtures;

final target = BoardResolver.resolve(
  'https://bbs.jpnkn.com/test/read.cgi/sample/100/',
)!;

class CompletedClient extends BoardClient {
  int lastPost = 1000;
  @override
  Future<BoardThread> fetch(BoardTarget target) async =>
      BoardThread('配信 Part1', [BoardPost(lastPost, '名無し', '', '本文')]);
  @override
  Future<List<BoardThreadEntry>> fetchThreads(BoardTarget target) async => [
    BoardThreadEntry(target.threadTarget('200'), '配信 Part2', 3),
  ];
}

void main() {
  test('各掲示板のsubject.txtとスレッドURLを復元する', () async {
    for (final row in [
      [
        'https://bbs.jpnkn.com/sample/',
        '/sample/subject.txt',
        '200.dat<>配信 &amp; 雑談 (12)',
        '/test/read.cgi/sample/200/',
      ],
      [
        'https://jbbs.shitaraba.net/game/123/',
        '/game/123/subject.txt',
        '200.cgi,配信 &amp; 雑談(12)',
        '/bbs/read.cgi/game/123/200/',
      ],
      [
        'http://www.dmdbs.net/kizuna/sample/',
        '/kizuna/sample/subject.txt',
        '200.dat<>配信 &amp; 雑談 (12)',
        '/kizuna/test/read.cgi/sample/200/',
      ],
    ]) {
      final board = BoardResolver.resolve(row[0])!;
      final client = BoardClient(
        client: MockClient((request) async {
          expect(request.url.path, row[1]);
          return http.Response(
            row[2],
            200,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }),
      );
      final entries = await client.fetchThreads(board);
      expect(entries.single.title, '配信 & 雑談');
      expect(entries.single.count, 12);
      expect(entries.single.target.uri.path, row[3]);
      expect(entries.single.target.boardUri, board.boardUri);
      client.dispose();
    }
  });

  test('次スレは同じシリーズか末尾の同一掲示板リンクを選ぶ', () async {
    final client = BoardClient(
      client: MockClient(
        (_) async => http.Response(
          '300.dat<>別の配信 (1)\n200.dat<>配信 Part2 (3)\n150.dat<>配信 Part0 (1000)',
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        ),
      ),
    );
    addTearDown(client.dispose);
    expect(
      (await client.nextThread(
        target,
        const BoardThread('配信 Part1', []),
      ))?.threadKey,
      '200',
    );
    expect(
      await client.nextThread(target, const BoardThread('無関係', [])),
      isNull,
    );
    expect(
      (await client.nextThread(
        target,
        BoardThread('配信 Part1', [
          BoardPost(1000, '', '', target.threadTarget('300').uri.toString()),
        ]),
      ))?.threadKey,
      '300',
    );
  });

  testWidgets('閲覧中に1000レスに到達すると次スレに移動し、一覧も選択できる', (tester) async {
    final client = CompletedClient()..lastPost = 999;
    addTearDown(client.dispose);
    BoardTarget? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadView(
            target: target,
            client: client,
            onNextThread: (v) => selected = v,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, isNull);
    client.lastPost = 1000;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(selected?.threadKey, '200');
    selected = null;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadListView(
            target: target,
            client: client,
            onSelected: (v) => selected = v,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('配信 Part2'));
    expect(selected?.threadKey, '200');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('完走済みのスレッドを開いても初回・手動更新・自動更新で移動しない', (tester) async {
    final client = CompletedClient();
    addTearDown(client.dispose);
    var moves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadView(
            target: target,
            client: client,
            onNextThread: (_) => moves++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(moves, 0);
    await tester.tap(find.byTooltip('更新'));
    await tester.pumpAndSettle();
    expect(moves, 0);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(moves, 0);
    expect(find.text('配信 Part1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('回転後も可変高さのレス一覧の末尾に追従する', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 850);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final client = fixtures.FakeBoardClient()..count = 150;
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: .6,
              child: ThreadView(target: target, client: client),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(850, 400);
    await tester.pumpAndSettle();
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(scroll.position.extentAfter, closeTo(0, 1));
    expect(find.byKey(const ValueKey(150)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('復帰で一覧を更新し、非公開チャンネルをステータスより上に表示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    var calls = 0;
    String line(String name, String id, String listeners) {
      final fields = List.filled(19, '');
      fields[0] = name;
      fields[1] = id;
      fields[6] = listeners;
      return fields.join('<>');
    }

    final directory = ChannelDirectory(
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes(
          utf8.encode(
            [
              line('ステータス', '00000000000000000000000000000000', '0'),
              line('非公開配信', '11111111111111111111111111111111', '-1'),
            ].join('\n'),
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(MyApp(settings: settings, directory: directory));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('非公開配信').first).dy,
      lessThan(tester.getTopLeft(find.text('ステータス').first).dy),
    );
    final before = calls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, greaterThan(before));
    await tester.pumpWidget(const SizedBox());
  });
}
