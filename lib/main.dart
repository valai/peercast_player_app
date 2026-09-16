import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'models/channel.dart';
import 'services/app_settings.dart';
import 'services/channel_directory.dart';
import 'services/screenshot_channel_directory.dart';
import 'screens/settings_screen.dart';
import 'screens/keyboard_dismiss.dart';
import 'screens/watch_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  if (defaultTargetPlatform != TargetPlatform.android) {
    MediaKit.ensureInitialized();
  }
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'PeerCast YT (GPL-2.0-or-later)',
    ], await rootBundle.loadString('assets/licenses/peercast-gpl.txt'));
    yield LicenseEntryWithLineBreaks([
      'BoringSSL',
    ], await rootBundle.loadString('assets/licenses/boringssl.txt'));
  });
  final settings = await AppSettings.load();
  // スクショ撮影後は false に戻すと通常のチャンネル一覧に戻る。
  const screenshotMode = bool.fromEnvironment(
    'SCREENSHOT_MODE',
    defaultValue: false,
  );
  runApp(
    MyApp(
      settings: settings,
      directory: screenshotMode ? ScreenshotChannelDirectory() : null,
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.settings, this.directory});
  final AppSettings settings;
  final ChannelDirectory? directory;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => MaterialApp(
      title: 'ぺかわん',
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => KeyboardDismiss(child: child!),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff167f8b)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff167f8b),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: settings.themeMode,
      home: ChannelScreen(settings: settings, directory: directory),
    ),
  );
}

class ChannelScreen extends StatefulWidget {
  const ChannelScreen({super.key, required this.settings, this.directory});
  final AppSettings settings;
  final ChannelDirectory? directory;
  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen>
    with WidgetsBindingObserver {
  late final directory = widget.directory ?? ChannelDirectory();
  List<Channel> channels = [];
  Set<String> orderingFavorites = {};
  Map<String, String> errors = {};
  bool loading = false;
  final searchFocus = FocusNode();
  String search = '';
  int tab = 0;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.settings.addListener(changed);
    searchFocus.addListener(changed);
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> refresh() async {
    final request = ++generation;
    final favorites = Set<String>.of(widget.settings.favorites);
    setState(() => loading = true);
    final result = await directory.refresh(List.of(widget.settings.sources));
    if (!mounted || request != generation) return;
    setState(() {
      channels = result.channels;
      // Keep row positions stable until the next directory refresh.
      orderingFavorites = favorites;
      errors = result.errors;
      loading = false;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.settings.removeListener(changed);
    searchFocus.dispose();
    directory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = (tab == 2 ? widget.settings.history.take(10) : channels)
        .where(
          (c) =>
              (tab != 1 || widget.settings.favorites.contains(c.key)) &&
              '${c.name} ${c.genre} ${c.description} ${c.comment}'
                  .toLowerCase()
                  .contains(search.toLowerCase()),
        )
        .toList();
    if (tab != 2) {
      final originalOrder = {for (var i = 0; i < list.length; i++) list[i]: i};
      list.sort((a, b) {
        final byFavorite = (orderingFavorites.contains(b.key) ? 1 : 0)
            .compareTo(orderingFavorites.contains(a.key) ? 1 : 0);
        if (byFavorite != 0) return byFavorite;
        final byStatus = (a.isStatus ? 1 : 0).compareTo(b.isStatus ? 1 : 0);
        if (byStatus != 0) return byStatus;
        final aCount = a.listeners < 0 ? -1 : a.listeners;
        final bCount = b.listeners < 0 ? -1 : b.listeners;
        final byListeners = bCount.compareTo(aCount);
        return byListeners != 0
            ? byListeners
            : originalOrder[a]!.compareTo(originalOrder[b]!);
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('ぺかわん'),
        actions: [
          if (tab == 2)
            IconButton(
              tooltip: '閲覧履歴をリセット',
              icon: const Icon(Icons.delete_outline),
              onPressed: widget.settings.history.isEmpty
                  ? null
                  : () async {
                      try {
                        await widget.settings.clearHistory();
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('閲覧履歴を削除できませんでした: $e')),
                          );
                        }
                      }
                    },
            ),
          IconButton(
            tooltip: '更新',
            onPressed: loading ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '設定',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(settings: widget.settings),
                ),
              );
              if (mounted) await refresh();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              focusNode: searchFocus,
              onTapOutside: (_) => searchFocus.unfocus(),
              decoration: const InputDecoration(
                hintText: 'チャンネル・配信内容を検索',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => search = v),
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          if (widget.settings.loadError != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(widget.settings.loadError!),
            ),
          if (errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                errors.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                RefreshIndicator(
                  onRefresh: refresh,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: list.isEmpty ? 1 : list.length,
                    itemBuilder: (context, index) {
                      if (list.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Text(
                              loading
                                  ? 'チャンネルを取得しています…'
                                  : tab == 2
                                  ? '閲覧履歴はありません'
                                  : widget.settings.sources.isEmpty
                                  ? '設定からYPを追加してください'
                                  : '該当するチャンネルはありません',
                            ),
                          ),
                        );
                      }
                      final c = list[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: ListTile(
                          title: Text(
                            c.name,
                            style: const TextStyle(color: Colors.blue),
                          ),
                          subtitle: Text(
                            '${c.sourceName} · ${c.format} · ${c.bitrate} kbps · ${c.broadcastDurationLabel()} · ${c.listeners < 0 ? "視聴者数非公開" : "${c.listeners}人"}\n${[c.genre, c.description, c.comment].where((v) => v.isNotEmpty).join(" / ")}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'お気に入り',
                            icon: Icon(
                              widget.settings.favorites.contains(c.key)
                                  ? Icons.star
                                  : Icons.star_border,
                            ),
                            onPressed: () async {
                              try {
                                await widget.settings.toggleFavorite(c);
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showSnackBar(SnackBar(content: Text('$e')));
                                }
                              }
                            },
                          ),
                          onTap: () async {
                            try {
                              await widget.settings.remember(c);
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('履歴を保存できませんでした: $e')),
                                );
                              }
                            }
                            if (context.mounted) {
                              await Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => WatchScreen(
                                    channel: c,
                                    settings: widget.settings,
                                  ),
                                ),
                              );
                              if (mounted) await refresh();
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
                if (searchFocus.hasFocus ||
                    MediaQuery.viewInsetsOf(context).bottom > 0)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => searchFocus.unfocus(),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.live_tv), label: 'チャンネル'),
          NavigationDestination(icon: Icon(Icons.star_outline), label: 'お気に入り'),
          NavigationDestination(icon: Icon(Icons.history), label: '閲覧履歴'),
        ],
      ),
    );
  }
}
