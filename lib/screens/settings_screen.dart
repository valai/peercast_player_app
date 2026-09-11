import 'package:flutter/material.dart';

import '../models/channel.dart';
import 'port_check_screen.dart';
import 'upnp_screen.dart';
import '../services/app_settings.dart';
import '../services/upnp_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings});
  final AppSettings settings;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool portValid = true;
  Future<void> save() async {
    try {
      await widget.settings.save();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> edit([YellowPage? source]) async {
    final value = await showDialog<YellowPage>(
      context: context,
      builder: (_) =>
          SourceDialog(source: source, sources: widget.settings.sources),
    );
    if (value != null && mounted) {
      final index = widget.settings.sources.indexWhere((s) => s.id == value.id);
      if (index < 0) {
        widget.settings.sources.add(value);
      } else {
        widget.settings.sources[index] = value;
      }
      await save();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: const Text('テーマ'),
            trailing: DropdownButton<ThemeMode>(
              value: s.themeMode,
              items: const [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text('端末に合わせる'),
                ),
                DropdownMenuItem(value: ThemeMode.light, child: Text('ライト')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('ダーク')),
              ],
              onChanged: (value) async {
                if (value == null) return;
                s.themeMode = value;
                await save();
              },
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.history),
            title: const Text('閲覧履歴を残す'),
            subtitle: const Text('直近10件を保存します。オフにすると履歴を削除します。'),
            value: s.historyEnabled,
            onChanged: (value) async {
              s.historyEnabled = value;
              await save();
            },
          ),
          const Divider(),
          ListTile(
            title: const Text('YellowPage'),
            subtitle: const Text('有効なYPからチャンネルを取得します'),
            trailing: IconButton(
              tooltip: 'YPを追加',
              onPressed: edit,
              icon: const Icon(Icons.add),
            ),
          ),
          for (final source in s.sources)
            ListTile(
              title: Text(source.name),
              subtitle: Text(source.url),
              onTap: () => edit(source),
              leading: Switch(
                value: source.enabled,
                onChanged: (value) async {
                  s.sources[s.sources.indexOf(source)] = source.copyWith(
                    enabled: value,
                  );
                  await save();
                },
              ),
              trailing: IconButton(
                tooltip: '${source.name}を削除',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  s.sources.remove(source);
                  await save();
                },
              ),
            ),
          if (s.sources.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('YPは未登録です。＋から追加できます。'),
            ),
          const Divider(),
          const ListTile(
            title: Text('視聴・リレー'),
            subtitle: Text('Wi-Fi接続とポート開放が必要です。視聴中は必ずリレーを行い、バックグラウンド移行で停止します。'),
          ),
          ListTile(
            title: const Text('下流の最大接続数'),
            trailing: DropdownButton<int>(
              value: s.maxRelays,
              items: List.generate(
                16,
                (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
              ),
              onChanged: (v) async {
                if (v != null) {
                  s.maxRelays = v;
                  await save();
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextFormField(
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              initialValue: '${s.port}',
              decoration: const InputDecoration(
                labelText: '待受ポート (1024–65535)',
              ),
              keyboardType: TextInputType.number,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) {
                final port = int.tryParse(v ?? '');
                return port == null || port < 1024 || port > 65535
                    ? '1024〜65535で入力してください'
                    : null;
              },
              onChanged: (v) async {
                final port = int.tryParse(v);
                setState(
                  () =>
                      portValid = port != null && port >= 1024 && port <= 65535,
                );
                if (port != null && port >= 1024 && port <= 65535) {
                  s.port = port;
                  await save();
                }
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('リレーの可否は外部からの到達確認が必要です。待受ポートの設定だけではリレー可能になりません。'),
          ),
          ListTile(
            enabled: portValid && UpnpService.isSupported,
            leading: const Icon(Icons.router),
            title: const Text('UPnPで自動ポート開放'),
            subtitle: Text(
              UpnpService.isSupported
                  ? 'ルーターを検出してTCP ${s.port} を開放・削除します'
                  : UpnpService.unavailableMessage,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: !portValid || !UpnpService.isSupported
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          UpnpScreen(port: s.port, relays: s.maxRelays),
                    ),
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.network_check),
            title: const Text('SPでポート開放を確認'),
            subtitle: Text('ポート ${s.port} で確認用の待受を開始します'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    PortCheckScreen(port: s.port, relays: s.maxRelays),
              ),
            ),
          ),
          ListTile(
            title: const Text('ライセンス'),
            onTap: () =>
                showLicensePage(context: context, applicationName: 'PeerCast'),
          ),
        ],
      ),
    );
  }
}

class SourceDialog extends StatefulWidget {
  const SourceDialog({super.key, this.source, required this.sources});
  final YellowPage? source;
  final List<YellowPage> sources;
  @override
  State<SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<SourceDialog> {
  late final name = TextEditingController(text: widget.source?.name ?? '');
  late final url = TextEditingController(text: widget.source?.url ?? '');
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.source == null ? 'YPを追加' : 'YPを編集'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              controller: name,
              decoration: const InputDecoration(labelText: '名前'),
              validator: (v) => (v ?? '').trim().isEmpty ? '名前を入力してください' : null,
            ),
            TextFormField(
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              controller: url,
              decoration: const InputDecoration(
                labelText: 'index.txt URL',
                helperText: '追加YPにはHTTPSを推奨',
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                if (webUri(v ?? '') == null) return 'HTTP/HTTPSのURLを入力してください';
                if (widget.sources.any(
                  (s) => s.id != widget.source?.id && s.url == v!.trim(),
                )) {
                  return 'このURLは登録済みです';
                }
                return null;
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(
              context,
              YellowPage(
                id:
                    widget.source?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                name: name.text.trim(),
                url: url.text.trim(),
                enabled: widget.source?.enabled ?? true,
              ),
            );
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
