import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../services/upnp_service.dart';
import 'port_check_screen.dart';

class UpnpScreen extends StatefulWidget {
  const UpnpScreen({
    super.key,
    required this.port,
    required this.relays,
    this.service,
    this.checkConnectivity,
  });
  final int port, relays;
  final UpnpService? service;
  final Future<List<ConnectivityResult>> Function()? checkConnectivity;
  @override
  State<UpnpScreen> createState() => _UpnpScreenState();
}

class _UpnpScreenState extends State<UpnpScreen> {
  late final service = widget.service ?? UpnpService();
  bool busy = false;
  String message = 'Wi-Fiルーターを自動検出し、この端末へのTCPポート転送を設定します。';

  Future<void> run({required bool remove}) async {
    if (busy || !UpnpService.isSupported) return;
    setState(() {
      busy = true;
      message =
          'ルーターを検出してTCP ${widget.port} の${remove ? '転送を削除' : 'ポートを開放'}しています…';
    });
    try {
      final links =
          await (widget.checkConnectivity ??
              Connectivity().checkConnectivity)();
      if (!links.contains(ConnectivityResult.wifi) ||
          links.contains(ConnectivityResult.none)) {
        throw const UpnpException('Wi-Fiに接続してください。');
      }
      final result = await (remove
          ? service.remove(widget.port)
          : service.open(widget.port));
      if (mounted) setState(() => message = result);
    } catch (e) {
      final detail = switch (e) {
        UpnpException() => e.message,
        TimeoutException() =>
          'ルーターとの通信がタイムアウトしました。登録・削除が反映された可能性があるため、ルーターの設定を確認してから再試行してください。',
        SocketException() => 'ルーターに接続できません。Wi-Fiとローカルネットワーク権限を確認してください。',
        _ => 'UPnP処理に失敗しました。ルーターの設定と接続を確認して再試行してください。',
      };
      if (mounted) setState(() => message = detail);
    } finally {
      if (mounted) {
        setState(() => busy = false);
      } else if (widget.service == null) {
        service.dispose();
      }
    }
  }

  @override
  void dispose() {
    if (!busy && widget.service == null) service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('UPnPで自動ポート開放')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '待受ポート: TCP ${widget.port}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'ルーター側でUPnPを有効にしてください。開放したポートはアプリを閉じても残ります。不要になった場合や待受ポートを変更する前に、この画面で転送を削除してください。',
          ),
          const SizedBox(height: 16),
          if (busy) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              UpnpService.isSupported
                  ? message
                  : UpnpService.unavailableMessage,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: busy || !UpnpService.isSupported
                ? null
                : () => run(remove: false),
            icon: const Icon(Icons.router),
            label: const Text('自動でポートを開放'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy || !UpnpService.isSupported
                ? null
                : () => run(remove: true),
            icon: const Icon(Icons.link_off),
            label: const Text('このポートの転送を削除'),
          ),
          const SizedBox(height: 16),
          const Text(
            '登録成功だけでは外部からの到達を保証しません。二重ルーターや回線側の制限がある場合は、UPnPで開放できないことがあります。Wi-Fiや端末のIPアドレスが変わった場合は再設定してください。',
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: busy
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => PortCheckScreen(
                        port: widget.port,
                        relays: widget.relays,
                      ),
                    ),
                  ),
            icon: const Icon(Icons.network_check),
            label: const Text('SPでポート開放を確認'),
          ),
        ],
      ),
    ),
  );
}
