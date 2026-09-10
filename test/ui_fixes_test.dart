import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:peercast_app/main.dart';
import 'package:peercast_app/screens/keyboard_dismiss.dart';
import 'package:peercast_app/screens/thread_view.dart';
import 'package:peercast_app/services/app_settings.dart';
import 'package:peercast_app/services/board_client.dart';
import 'package:peercast_app/services/board_resolver.dart';
import 'package:peercast_app/services/channel_directory.dart';

import 'board_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Shift_JIS表記のDATをCP932で読み取る', () async {
    const channel = MethodChannel('charset_converter');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.arguments['charset'], 'cp932');
          expect(call.arguments['data'], [0x87, 0x70]);
          return '㎰';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final client = BoardClient();
    addTearDown(client.dispose);
    expect(
      await client.decode(
        http.Response.bytes(
          [0x87, 0x70],
          200,
          headers: {'content-type': 'text/plain; charset=Shift_JIS'},
        ),
        BoardResolver.resolve(
          'https://bbs.jpnkn.com/test/read.cgi/sample/123/',
        )!,
      ),
      '㎰',
    );
  });

  testWidgets('設定から戻ると一覧を再取得し、ポート入力を外タップで閉じる', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    var calls = 0;
    final directory = ChannelDirectory(
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes(utf8.encode(''), 200);
      }),
    );
    await tester.pumpWidget(MyApp(settings: settings, directory: directory));
    await tester.pumpAndSettle();
    final before = calls;
    await tester.tap(find.byTooltip('設定'));
    await tester.pumpAndSettle();
    final port = find.byType(TextFormField);
    await tester.ensureVisible(port);
    await tester.showKeyboard(port);
    await tester.tap(find.text('視聴・リレー'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, false);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(calls, greaterThan(before));
  });

  testWidgets('狭い投稿領域とキーボードでもはみ出さずチェックで閉じる', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final client = fixtures.FakeBoardClient()..count = 50;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => KeyboardDismiss(child: child!),
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 260),
              Expanded(
                child: ThreadView(
                  target: BoardResolver.resolve(
                    'https://jbbs.shitaraba.net/bbs/read.cgi/game/123/456/',
                  )!,
                  client: client,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    final scroll = tester.widget<ListView>(list).controller!;
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('書き込み'));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    final panel = find
        .ancestor(
          of: find.byType(TextField).last,
          matching: find.byType(Material),
        )
        .first;
    expect(tester.getBottomLeft(panel).dy, closeTo(874, 1));
    await tester.enterText(find.byType(TextField).last, '下書き');
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    await tester.tap(find.byTooltip('入力を確定してキーボードを閉じる'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, false);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      '下書き',
    );
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(3));
    expect(tester.getBottomLeft(panel).dy, closeTo(874, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    client.dispose();
  });
}
