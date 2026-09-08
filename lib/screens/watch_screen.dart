import 'dart:async';
import 'dart:io';

import 'package:video_player/video_player.dart';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/playback_controller.dart';

import 'package:webview_flutter/webview_flutter.dart';

import '../models/channel.dart';
import '../services/app_settings.dart';
import '../services/board_resolver.dart';
import 'thread_view.dart';

class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.channel, required this.settings});
  final Channel channel;
  final AppSettings settings;
  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> with WidgetsBindingObserver {
  late final PlaybackController playback = PlaybackController(
    settings: widget.settings,
  );
  WebViewController? board;
  BoardTarget? target;
  String? boardError;
  bool loading = false;
  bool fullscreen = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(playback.start(widget.channel));
    target = BoardResolver.resolve(
      widget.settings.threads[widget.channel.key] ?? widget.channel.contact,
    );
    if (target != null && !target!.isThread) {
      loadBoard(target!.uri);
    }
  }

  void loadBoard(Uri uri) {
    board ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (!mounted) return NavigationDecision.prevent;
            final next = BoardResolver.resolve(request.url);
            if (next?.isThread == true) {
              selectThread(next!);
              return NavigationDecision.prevent;
            }
            return webUri(request.url) == null
                ? NavigationDecision.prevent
                : NavigationDecision.navigate;
          },
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                loading = true;
                boardError = null;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) setState(() => loading = false);
          },
          onWebResourceError: (e) {
            if (mounted && e.isForMainFrame == true) {
              setState(() {
                loading = false;
                boardError = '掲示板を読み込めませんでした: ${e.description}';
              });
            }
          },
        ),
      );
    unawaited(board!.loadRequest(uri));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(playback.stop(message: 'バックグラウンドに移動したため停止しました'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    playback.dispose();
    super.dispose();
  }

  Widget video() => ListenableBuilder(
    listenable: playback,
    builder: (context, _) {
      final reachability = switch (playback.snapshot.firewall) {
        'reachable' => '外部から接続可能',
        'blocked' => 'リレー不可（着信できません）',
        _ => '外部からの到達性は未確認',
      };
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: Platform.isAndroid
                  ? (playback.androidVideo?.value.isInitialized == true
                        ? Center(
                            child: AspectRatio(
                              aspectRatio:
                                  playback.androidVideo!.value.aspectRatio,
                              child: VideoPlayer(playback.androidVideo!),
                            ),
                          )
                        : const SizedBox.shrink())
                  : Video(
                      controller: playback.video,
                      controls: NoVideoControls,
                    ),
            ),
            if (playback.opening)
              const Center(child: CircularProgressIndicator()),
            if (!playback.active)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    playback.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            Positioned(
              left: 4,
              right: 4,
              bottom: 0,
              child: ColoredBox(
                color: Colors.black54,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (playback.active)
                      Text(
                        '${playback.snapshot.relays}接続 · 外部送信 ${(playback.snapshot.bytesOut / 1048576).toStringAsFixed(1)} MB · $reachability',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: playback.active ? '視聴を停止' : '視聴を開始',
                          color: Colors.white,
                          icon: Icon(
                            playback.active ? Icons.stop : Icons.play_arrow,
                          ),
                          onPressed: () => playback.active
                              ? playback.stop()
                              : playback.start(widget.channel),
                        ),
                        TextButton(
                          onPressed:
                              !playback.active || widget.settings.maxRelays == 0
                              ? null
                              : playback.toggleRelay,
                          child: Text(
                            playback.relayEnabled && playback.active
                                ? 'リレー停止'
                                : 'リレー開始',
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: fullscreen ? '全画面を終了' : '全画面',
                          color: Colors.white,
                          icon: Icon(
                            fullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                          ),
                          onPressed: () =>
                              setState(() => fullscreen = !fullscreen),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  Uri boardHome(BoardTarget value) {
    final p = value.threadParts;
    return value.uri.replace(
      path: value.type == BoardType.shitaraba
          ? '/${p[2]}/${p[3]}/'
          : '${value.pathPrefix}/${p[2]}/',
      query: '',
      fragment: '',
    );
  }

  void selectThread(BoardTarget next) {
    setState(() => target = next);
    widget.settings.threads[widget.channel.key] = next.uri.toString();
    unawaited(
      widget.settings.save().catchError((Object e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('スレッドの保存に失敗しました: $e')));
        }
      }),
    );
  }

  Widget boardView() => target?.isThread == true
      ? Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final home = boardHome(target!);
                  setState(
                    () => target = BoardResolver.resolve(home.toString()),
                  );
                  loadBoard(home);
                },
                icon: const Icon(Icons.arrow_back),
                label: const Text('スレッド一覧'),
              ),
            ),
            Expanded(
              child: ThreadView(
                key: ValueKey(target!.uri.toString()),
                target: target!,
              ),
            ),
          ],
        )
      : Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '戻る',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: board == null
                      ? null
                      : () async {
                          if (await board!.canGoBack()) await board!.goBack();
                        },
                ),
                Expanded(
                  child: Text(
                    target == null
                        ? '掲示板未設定'
                        : '${target!.label} · ${target!.isThread ? "スレッド" : "スレッドを選択してください"}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '掲示板トップ',
                  icon: const Icon(Icons.home_outlined),
                  onPressed:
                      webUri(widget.channel.contact) == null || board == null
                      ? null
                      : () =>
                            board!.loadRequest(webUri(widget.channel.contact)!),
                ),
                IconButton(
                  tooltip: '掲示板を更新',
                  icon: const Icon(Icons.refresh),
                  onPressed: board?.reload,
                ),
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            if (boardError != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(boardError!),
              ),
            Expanded(
              child: board == null
                  ? const Center(child: Text('有効なコンタクトURLがありません'))
                  : WebViewWidget(controller: board!),
            ),
          ],
        );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !fullscreen,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && fullscreen) setState(() => fullscreen = false);
    },
    child: Scaffold(
      appBar: fullscreen ? null : AppBar(title: Text(widget.channel.name)),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final landscape =
                MediaQuery.orientationOf(context) == Orientation.landscape;
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final videoWidth = fullscreen || !landscape ? width : width * .5;
            final videoHeight = fullscreen || landscape
                ? height
                : (width * 9 / 16).clamp(0.0, height * .5);
            // Stable sibling positions preserve both native views during rotation,
            // keyboard resizing and fullscreen transitions.
            return Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  width: videoWidth,
                  height: videoHeight,
                  child: video(),
                ),
                Positioned(
                  left: landscape ? width * .5 : 0,
                  top: landscape ? 0 : videoHeight,
                  right: 0,
                  bottom: 0,
                  child: Offstage(offstage: fullscreen, child: boardView()),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
