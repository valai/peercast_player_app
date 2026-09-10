import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// A browser confined to the response area; the thread remains mounted beneath it.
class ThreadWebView extends StatefulWidget {
  const ThreadWebView({super.key, required this.url, required this.onClose});
  final Uri url;
  final VoidCallback onClose;

  @override
  State<ThreadWebView> createState() => _ThreadWebViewState();
}

class _ThreadWebViewState extends State<ThreadWebView> {
  WebViewController? controller;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    try {
      final web = WebViewController();
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri != null &&
                    (uri.scheme == 'http' || uri.scheme == 'https')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                loading = true;
                error = null;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) setState(() => loading = false);
          },
          onWebResourceError: (failure) {
            if (mounted && failure.isForMainFrame == true) {
              setState(() {
                loading = false;
                error = 'ページを読み込めませんでした';
              });
            }
          },
        ),
      );
      if (!mounted) return;
      setState(() => controller = web);
      await web.loadRequest(widget.url);
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'WebViewを開けませんでした';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) widget.onClose();
    },
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Row(
            children: [
              TextButton.icon(
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back),
                label: const Text('レスに戻る'),
              ),
              Expanded(
                child: Text(
                  widget.url.toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'ページを再読み込み',
                onPressed: () {
                  if (controller == null) {
                    initialize();
                  } else {
                    controller!.reload();
                  }
                },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          Expanded(
            child: controller == null
                ? const SizedBox.shrink()
                : WebViewWidget(controller: controller!),
          ),
        ],
      ),
    ),
  );
}
