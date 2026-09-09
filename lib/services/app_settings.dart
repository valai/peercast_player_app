import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';

class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);
  final SharedPreferences _prefs;
  static const storageKey = 'peercast.settings.v1';
  List<YellowPage> sources = List.of(YellowPage.defaults);
  Set<String> favorites = {};
  List<Channel> history = [];
  Map<String, String> threads = {};
  bool wifiOnly = true;
  int maxRelays = 1;
  int port = 7145;
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
        settings.threads = Map<String, String>.from(j['threads'] as Map);
        settings.wifiOnly = j['wifiOnly'] as bool;
        settings.maxRelays = (j['maxRelays'] as int).clamp(0, 16);
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
        'threads': threads,
        'wifiOnly': wifiOnly,
        'maxRelays': maxRelays,
        'port': port,
      }),
    );
    if (!ok) throw StateError('設定を保存できませんでした');
    notifyListeners();
  }

  Future<void> toggleFavorite(Channel c) async {
    if (!favorites.remove(c.key)) favorites.add(c.key);
    await save();
  }

  Future<void> remember(Channel c) async {
    history = [c, ...history.where((v) => v.key != c.key)].take(100).toList();
    await save();
  }
}
