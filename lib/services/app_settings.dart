import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';

class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);
  final SharedPreferences _prefs;
  static const storageKey = 'peercast.settings.v1';
  List<YellowPage> sources = List.of(YellowPage.defaults);
  Set<String> favorites = {};
  List<Channel> history = [];
  bool _historyEnabled = true;
  bool get historyEnabled => _historyEnabled;
  set historyEnabled(bool value) {
    _historyEnabled = value;
    if (!value) history = [];
  }

  Map<String, String> threads = {};
  int _maxRelays = 1;
  int get maxRelays => _maxRelays;
  set maxRelays(int value) => _maxRelays = value.clamp(1, 16);
  int port = 7145;
  ThemeMode themeMode = ThemeMode.system;
  String? loadError;
  static Future<AppSettings> load() async {
    final settings = AppSettings(await SharedPreferences.getInstance());
    final raw = settings._prefs.getString(storageKey);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        settings.sources = (j['sources'] as List)
            .map((v) => YellowPage.fromJson(v as Map<String, dynamic>))
            .toList();
        settings.favorites = (j['favorites'] as List).cast<String>().toSet();
        settings.history = (j['history'] as List)
            .map((v) => Channel.fromJson(v as Map<String, dynamic>))
            .toList();
        settings.history = settings.history.take(10).toList();
        settings.historyEnabled = j['historyEnabled'] as bool? ?? true;
        settings.threads = Map<String, String>.from(j['threads'] as Map);
        settings.maxRelays = (j['maxRelays'] as int).clamp(1, 16);
        settings.themeMode = ThemeMode.values.firstWhere(
          (mode) => mode.name == j['themeMode'],
          orElse: () => ThemeMode.system,
        );
        settings.port = (j['port'] as int).clamp(1024, 65535);
      } catch (_) {
        settings.sources = [];
        settings.loadError = '保存データを読み込めませんでした。YP設定を確認してください。';
      }
    } else {
      await settings.save();
    }
    return settings;
  }

  Future<void> save() async {
    final ok = await _prefs.setString(
      storageKey,
      jsonEncode({
        'sources': sources.map((s) => s.toJson()).toList(),
        'favorites': favorites.toList(),
        'history': history.map((c) => c.toJson()).toList(),
        'historyEnabled': historyEnabled,
        'threads': threads,
        'maxRelays': maxRelays,
        'port': port,
        'themeMode': themeMode.name,
      }),
    );
    if (!ok) throw StateError('設定を保存できませんでした');
    notifyListeners();
  }

  Future<void> toggleFavorite(Channel c) async {
    if (!favorites.remove(c.key)) favorites.add(c.key);
    await save();
  }

  Future<void> clearHistory() async {
    history = [];
    await save();
  }

  Future<void> remember(Channel c) async {
    if (!historyEnabled) return;
    history = [c, ...history.where((v) => v.key != c.key)].take(10).toList();
    await save();
  }
}
