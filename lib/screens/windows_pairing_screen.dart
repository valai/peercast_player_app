import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/windows_mobile_api.dart';

class WindowsPairingScreen extends StatefulWidget {
  const WindowsPairingScreen({super.key, required this.store});
  final WindowsCredentialStore store;

  @override
  State<WindowsPairingScreen> createState() => _WindowsPairingScreenState();
}

class _WindowsPairingScreenState extends State<WindowsPairingScreen> {
  final scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool busy = false;
  String? error;

  Future<void> detected(BarcodeCapture capture) async {
    if (busy || error != null || capture.barcodes.isEmpty) return;
    final text = capture.barcodes.first.rawValue;
    if (text == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    await scanner.stop();
    try {
      final payload = PairPayload.parse(text);
      final credentials = await WindowsMobileApi.pair(payload);
      await widget.store.write(credentials);
      if (mounted) Navigator.of(context).pop(true);
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } on WindowsApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '登録情報を保存できませんでした');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Windowsとペアリング')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Windowsアプリで「ペアリングQRを作成」を押し、5分以内に読み取ってください。両端末でTailscaleに接続してください。',
          ),
        ),
        Expanded(
          child: MobileScanner(
            controller: scanner,
            onDetect: detected,
            errorBuilder: (context, error) =>
                const Center(child: Text('カメラを使用できません。端末のカメラ権限を確認してください。')),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton(
                  onPressed: () async {
                    setState(() => error = null);
                    await scanner.start();
                  },
                  child: const Text('もう一度読み取る'),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
