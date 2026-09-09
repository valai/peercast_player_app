import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:peercast_app/main.dart';
import 'package:peercast_app/screens/viewer_count.dart';
import 'package:peercast_app/models/channel.dart';
import 'package:peercast_app/services/app_settings.dart';
import 'package:peercast_app/services/board_resolver.dart';
import 'package:peercast_app/services/channel_directory.dart';

String row({
  String name = '日本語チャンネル',
  String id = '0123456789ABCDEF0123456789ABCDEF',
  String format = 'FLV',
}) => [
  name,
  id,
  '127.0.0.1:7144',
  'https://bbs.jpnkn.com/test/read.cgi/sample/123456/',
  'ゲーム',
  '説明 &lt;Free&gt;',
  '-1',
  '-1',
  '1500',
  format,
  '',
  '',
  '',
  '',
  '',
  '0:20',
  'click',
  'コメント',
  '0',
].join('<>');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('視聴者数を定期更新し非公開への変更も反映する', (tester) async {
    final settings = await AppSettings.load();
    var count = 12;
    var calls = 0;
    final directory = ChannelDirectory(
      client: MockClient((_) async {
        calls++;
        final fields = row().split('<>');
        fields[6] = '$count';
        return http.Response.bytes(utf8.encode(fields.join('<>')), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ViewerCount(
          channel: Channel.parse(row(), settings.sources.first).single,
          settings: settings,
          directory: directory,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('視聴者数: 12人'), findsOneWidget);
    count = 21;
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('視聴者数: 21人'), findsOneWidget);
    count = -1;
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('視聴者数非公開'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final stoppedCalls = calls;
    await tester.pump(const Duration(seconds: 20));
    expect(calls, stoppedCalls);
  });
  test('配信時間の解析・経過・保存互換性', () {
    final c = Channel.parse(row(), YellowPage.defaults.first).single;
    final start = c.broadcastStartedAt!;
    expect(
      c.broadcastDurationLabel(
        now: start.add(const Duration(hours: 25, minutes: 2, seconds: 3)),
      ),
      '配信時間: 25:02:03',
    );
    expect(DateTime.now().difference(start).inMinutes, 20);
    expect(Channel.fromJson(c.toJson()).broadcastStartedAt, start);
    final old = c.toJson()..remove('broadcastStartedAt');
    expect(Channel.fromJson(old).broadcastDurationLabel(), '配信時間: 不明');
    expect(
      Channel.parse(
        row().replaceFirst('0:20', 'invalid'),
        YellowPage.defaults.first,
      ).single.broadcastStartedAt,
      isNull,
    );
  });
  test('初期YPは一度だけ作成し全削除を再起動後も保持する', () async {
    final s = await AppSettings.load();
    expect(s.sources.map((v) => v.name), ['SP', 'p@']);
    expect((await AppSettings.load()).sources.length, 2);
    s.sources.clear();
    await s.save();
    expect((await AppSettings.load()).sources, isEmpty);
  });
  test('YPの追加・編集・無効化を保存する', () async {
    final s = await AppSettings.load();
    s.sources.add(
      const YellowPage(
        id: 'custom',
        name: '追加',
        url: 'https://example.com/index.txt',
      ),
    );
    s.sources[0] = s.sources[0].copyWith(name: '編集', enabled: false);
    await s.save();
    final restored = await AppSettings.load();
    expect(restored.sources.length, 3);
    expect(restored.sources.first.name, '編集');
    expect(restored.sources.first.enabled, false);
  });
  test('お気に入り・履歴・スレッド・リレー設定を保存する', () async {
    final s = await AppSettings.load();
    final c = Channel.parse(row(), YellowPage.defaults.first).single;
    await s.toggleFavorite(c);
    await s.remember(c);
    await s.remember(c);
    s.threads[c.key] = c.contact;
    s.wifiOnly = false;
    s.maxRelays = 2;
    s.port = 17144;
    await s.save();
    final restored = await AppSettings.load();
    expect(restored.favorites, contains(c.key));
    expect(restored.history.length, 1);
    expect(restored.threads[c.key], c.contact);
    expect(restored.port, 17144);
    expect(restored.maxRelays, 2);
    expect(restored.wifiOnly, false);
  });
  test('破損した保存データに初期YPを再挿入しない', () async {
    SharedPreferences.setMockInitialValues({AppSettings.storageKey: '{broken'});
    final s = await AppSettings.load();
    expect(s.sources, isEmpty);
    expect(s.loadError, isNotNull);
  });
  test('日本語・HTMLエンティティ・CRLF・BOMを解析する', () {
    final c = Channel.parse(
      '\uFEFF${row()}\r\n',
      YellowPage.defaults.first,
    ).single;
    expect(c.name, '日本語チャンネル');
    expect(c.description, '説明 <Free>');
    expect(c.sourceId, 'sp');
    expect(c.listeners, -1);
    expect(c.playable, true);
  });
  test('不正行を除外し重複IDをまとめる', () {
    expect(
      Channel.parse(
        'bad\n${row()}\n${row()}\n${row(id: "invalid")}',
        YellowPage.defaults.first,
      ).length,
      1,
    );
  });
  test('WMVとYPステータスは再生対象にしない', () {
    expect(
      Channel.parse(
        row(format: 'WMV'),
        YellowPage.defaults.first,
      ).single.playable,
      false,
    );
    expect(
      Channel.parse(
        row(id: '00000000000000000000000000000000'),
        YellowPage.defaults.first,
      ).single.playable,
      false,
    );
  });
  test('片方のYPが失敗してももう一方を取得する', () async {
    final directory = ChannelDirectory(
      client: MockClient(
        (request) async => request.url.host == 'p-at.net'
            ? http.Response('error', 503)
            : http.Response.bytes(utf8.encode(row()), 200),
      ),
    );
    final result = await directory.refresh(YellowPage.defaults);
    expect(result.channels.single.name, '日本語チャンネル');
    expect(result.errors.keys, ['p@']);
    directory.dispose();
  });
  test('無効YPへはアクセスしない', () async {
    var calls = 0;
    final directory = ChannelDirectory(
      client: MockClient((_) async {
        calls++;
        return http.Response('', 200);
      }),
    );
    await directory.refresh([
      YellowPage.defaults.first.copyWith(enabled: false),
    ]);
    expect(calls, 0);
    directory.dispose();
  });
  test('HTML応答を正常な空リストとして扱わない', () async {
    final directory = ChannelDirectory(
      client: MockClient((_) async => http.Response('<html>error</html>', 200)),
    );
    expect(
      (await directory.refresh([YellowPage.defaults.first])).errors,
      isNotEmpty,
    );
    directory.dispose();
  });
  test('JPNKNとしたらばの板・スレッドを識別する', () {
    expect(
      BoardResolver.resolve('https://bbs.jpnkn.com/sample/')!.isThread,
      false,
    );
    expect(
      BoardResolver.resolve('https://bbs.jpnkn.com/test/read.cgi/sample/123/')!
          .isThread,
      true,
    );
    final b = BoardResolver.resolve(
      'https://jbbs.shitaraba.net/bbs/read.cgi/game/123/456/',
    );
    expect(b!.type, BoardType.shitaraba);
    expect(b.isThread, true);
    expect(
      BoardResolver.resolve('http://jbbs.livedoor.jp/game/123/')!.isThread,
      false,
    );
    expect(
      BoardResolver.resolve(
        'https://bbs.jpnkn.com.evil.example/test/read.cgi/a/123/',
      )!.type,
      BoardType.other,
    );
  });
  test('不正なコンタクトURLと実行可能スキームを拒否する', () {
    for (final value in [
      '',
      'not a url',
      'javascript:alert(1)',
      'file:///tmp/a',
      'https:///path',
      'https://user:pass@example.com/',
    ]) {
      expect(BoardResolver.resolve(value), isNull, reason: value);
    }
  });
  testWidgets('一覧の検索・お気に入りと設定画面', (tester) async {
    final settings = await AppSettings.load();
    final directory = ChannelDirectory(
      client: MockClient(
        (r) async => http.Response.bytes(
          utf8.encode(r.url.host == 'p-at.net' ? '' : row()),
          200,
        ),
      ),
    );
    await tester.pumpWidget(MyApp(settings: settings, directory: directory));
    await tester.pumpAndSettle();
    expect(find.text('日本語チャンネル'), findsOneWidget);
    await tester.showKeyboard(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日本語チャンネル'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(settings.history, isEmpty);
    expect(find.byType(ChannelScreen), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.star_border));
    await tester.pumpAndSettle();
    expect(settings.favorites.length, 1);
    await tester.enterText(find.byType(TextField), '見つからない');
    await tester.pumpAndSettle();
    expect(find.text('該当するチャンネルはありません'), findsOneWidget);
    await tester.tap(find.byTooltip('設定'));
    await tester.pumpAndSettle();
    expect(find.text('SP'), findsOneWidget);
    expect(find.text('p@'), findsOneWidget);
    await tester.tap(find.byTooltip('SPを削除'));
    await tester.pumpAndSettle();
    expect((await AppSettings.load()).sources.map((s) => s.name), ['p@']);
  });
}
