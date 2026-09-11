import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:peercast_app/main.dart';
import 'package:peercast_app/services/app_settings.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('テーマを保存し、旧設定と未知の値は端末設定に従う', () async {
    final settings = await AppSettings.load();
    for (final mode in ThemeMode.values) {
      settings.themeMode = mode;
      await settings.save();
      expect((await AppSettings.load()).themeMode, mode);
    }
    final prefs = await SharedPreferences.getInstance();
    final json = jsonDecode(
      prefs.getString(AppSettings.storageKey)!,
    ) as Map<String, dynamic>;
    for (final value in [null, 'unknown']) {
      json['themeMode'] = value;
      if (value == null) json.remove('themeMode');
      await prefs.setString(AppSettings.storageKey, jsonEncode(json));
      final loaded = await AppSettings.load();
      expect(loaded.themeMode, ThemeMode.system);
      expect(loaded.loadError, isNull);
      expect(loaded.sources.length, settings.sources.length);
    }
  });

  testWidgets('設定で即時切替し、端末の明暗変更にも追従する', (tester) async {
    final settings = await AppSettings.load();
    settings.sources.clear();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(MyApp(settings: settings));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('設定'));
    await tester.pumpAndSettle();

    Brightness brightness() =>
        Theme.of(tester.element(find.text('テーマ'))).brightness;
    expect(brightness(), Brightness.light);
    await tester.tap(find.byType(DropdownButton<ThemeMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ダーク').last);
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    expect((await AppSettings.load()).themeMode, ThemeMode.dark);

    await tester.tap(find.byType(DropdownButton<ThemeMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ライト').last);
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);

    await tester.tap(find.byType(DropdownButton<ThemeMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('端末に合わせる').last);
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
  });
}
