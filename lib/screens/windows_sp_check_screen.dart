import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../services/windows_mobile_api.dart';

/// Windows から SP の一覧を取得し、同じ PC のリレー待受状態を確認する。
class WindowsSpCheckScreen extends StatefulWidget {
  const WindowsSpCheckScreen({super.key});

  @override
  State<WindowsSpCheckScreen> createState() => _WindowsSpCheckScreenState();
}

class _WindowsSpCheckScreenState extends State<WindowsSpCheckScreen> {
  bool checking = false;
  int? count;
  String? relayMessage;
  String? error;

  @override
  void initState() {
    super.initState();
    check();
  }

  Future<void> check() async {
    if (checking) return;
    setState(() {
      checking = true;
      error = null;
      count = null;
      relayMessage = null;
    });
    WindowsMobileApi? api;
    try {
      final credentials = await WindowsCredentialStore().read();
      if (credentials == null) throw StateError('設定からWindowsとペアリングしてください');
      api = WindowsMobileApi(credentials);
      final index = await api.fetchSpIndex();
      final channels = Channel.parse(index, YellowPage.defaults.first);
      if (index.trim().isNotEmpty && channels.isEmpty) {
        throw const FormatException('Windowsから取得したSPの一覧形式が正しくありません');
      }
      final status = await api.status();
      if (!mounted) return;
      setState(() {
        count = channels.where((channel) => !channel.isStatus).length;
        relayMessage = status.relayMessage;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => error = switch (e) {
            StateError() => e.message,
            FormatException() => e.message,
            _ => '$e',
          },
        );
      }
    } finally {
      api?.dispose();
      if (mounted) setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Windows経由でSPを確認')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'WindowsからSPへアクセスしてチャンネル一覧を取得します。SPが確認する接続元はスマホではなくWindowsです。',
        ),
        const SizedBox(height: 16),
        if (checking) const LinearProgressIndicator(),
        if (count != null) Text('SPから取得したチャンネル: $count 件'),
        if (relayMessage != null)
          Text('WindowsのPeerCastStation: $relayMessage'),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 16),
        const Text(
          'PeerCastStationの待受状態と、SP自身の「Port check」の判定は異なる場合があります。SPの詳細な判定や使用ポートの変更はWindows PCのブラウザでSPを開いて確認してください。',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: checking ? null : check,
          child: const Text('再確認'),
        ),
      ],
    ),
  );
}
