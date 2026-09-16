import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/port_check_controller.dart';

class PortCheckScreen extends StatefulWidget {
  const PortCheckScreen({super.key, required this.port, required this.relays});
  final int port, relays;
  @override
  State<PortCheckScreen> createState() => _PortCheckScreenState();
}

class _PortCheckScreenState extends State<PortCheckScreen>
    with WidgetsBindingObserver {
  late final listener = PortCheckController(
    port: widget.port,
    relays: widget.relays,
  );
  WebViewController? web;
  String? webError;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    listener.addListener(changed);
  }

  void changed() {
    if (!mounted) return;
    if (listener.listening && web == null) {
      web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              final uri = Uri.tryParse(request.url);
              return listener.listening &&
                      uri != null &&
                      (uri.scheme == 'http' || uri.scheme == 'https') &&
                      uri.host == 'bayonet.ddo.jp'
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
            onPageStarted: (_) {
              if (mounted) {
                setState(() {
                  loading = true;
                  webError = null;
                });
              }
            },
            onPageFinished: (_) {
              if (mounted) setState(() => loading = false);
            },
            onWebResourceError: (error) {
              if (mounted && error.isForMainFrame == true) {
                setState(() {
                  loading = false;
                  webError = 'SPを読み込めませんでした。更新して再試行してください';
                });
              }
            },
          ),
        );
      unawaited(open('port_update.php'));
    }
    setState(() {});
  }

  Future<void> open(String path) async {
    if (!listener.listening) return;
    try {
      await web?.loadRequest(Uri.parse('http://bayonet.ddo.jp/sp/$path'));
    } catch (_) {
      if (mounted) setState(() => webError = 'SPを読み込めませんでした');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(listener.stop('アプリが終了したため待受を停止しました'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    listener.removeListener(changed);
    listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('SPでポート開放を確認')),
    body: Column(
      children: [
        ListTile(
          title: Text(listener.message),
          subtitle: Text(
            'SPの使用ポートを ${widget.port} に変更し、確認結果の「Use Port」と「Port check」を確認してください。画面を閉じると待受を停止します。',
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: listener.listening
                  ? () => open('port_update.php')
                  : null,
              child: const Text('SPのポートを変更'),
            ),
            TextButton(
              onPressed: listener.listening ? () => open('') : null,
              child: const Text('確認結果を更新'),
            ),
            TextButton(
              onPressed: listener.starting
                  ? null
                  : () async {
                      if (listener.listening) {
                        await listener.stop();
                      } else {
                        await listener.start();
                      }
                    },
              child: Text(listener.listening ? '待受を停止' : '待受を再開'),
            ),
          ],
        ),
        if (webError != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(webError!)),
        if (loading && listener.listening) const LinearProgressIndicator(),
        Expanded(
          child: listener.listening && web != null
              ? WebViewWidget(controller: web!)
              : Center(
                  child: listener.starting
                      ? const CircularProgressIndicator()
                      : const Text('待受を再開するとSPで確認できます'),
                ),
        ),
      ],
    ),
  );
}
