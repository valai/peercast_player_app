import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/screens/thread_post_text.dart';

void main() {
  for (final scheme in ['http', 'https', 'ttp', 'ttps']) {
    testWidgets('$scheme のURLをタップするとHTTP(S)で開く', (tester) async {
      final text = '$scheme://example.com/path?q=1';
      final normalized = scheme.startsWith('ttp') ? 'h$text' : text;
      Uri? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThreadPostText(text, onOpenUrl: (url) => opened = url),
          ),
        ),
      );
      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText))
            .textSpan!
            .toPlainText(),
        text,
      );
      await tester.tapAt(
        tester.getTopLeft(find.byType(SelectableText)) + const Offset(25, 8),
      );
      await tester.pump();
      expect(opened, Uri.parse(normalized));
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform: 日本語メニューと外側タップで選択解除', (tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ja'),
          supportedLocales: const [Locale('ja')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: Column(
              children: [
                const ThreadPostText('選択するレス本文です'),
                const SizedBox(height: 100),
                TextButton(onPressed: () {}, child: const Text('外側')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ThreadPostText));
      expect(MaterialLocalizations.of(context).copyButtonLabel, 'コピー');
      expect(CupertinoLocalizations.of(context).copyButtonLabel, 'コピー');
      await tester.longPress(find.byType(SelectableText));
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(editable.textEditingValue.selection.isCollapsed, isFalse);
      expect(find.text('コピー'), findsWidgets);
      await tester.tap(find.text('外側'));
      await tester.pumpAndSettle();
      expect(editable.widget.focusNode.hasFocus, isFalse);
      expect(editable.textEditingValue.selection.isCollapsed, isTrue);
      expect(find.text('コピー'), findsNothing);
      // Outside-touch dismissal must not intercept the toolbar itself.
      await tester.longPress(find.byType(SelectableText));
      await tester.pumpAndSettle();
      final selected = editable.textEditingValue.selection.textInside(
        editable.textEditingValue.text,
      );
      await tester.tap(find.text('コピー').first);
      await tester.pumpAndSettle();
      expect(copiedText, selected);
    });
  }
}
