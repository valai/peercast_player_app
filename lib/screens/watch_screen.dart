import 'dart:async';

import 'package:video_player/video_player.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/fullscreen.dart';

import 'package:media_kit_video/media_kit_video.dart';

import '../services/playback_controller.dart';

import 'package:webview_flutter/webview_flutter.dart';

import '../models/channel.dart';
import '../services/app_settings.dart';
import '../services/board_resolver.dart';
import 'thread_view.dart';
import 'thread_list_view.dart';
import 'playback_overlay.dart';
import 'broadcast_clock.dart';
import 'viewer_count.dart';
import 'playback_viewport.dart';

class WatchScreen extends StatefulWidget {
  const WatchScreen({
    super.key,
    required this.channel,
    required this.settings,
    this.minimized = false,
    this.onMinimize,
    this.onRestore,
    this.onClose,
    this.onPipChanged,
    this.controller,
  });
  final Channel channel;
  final AppSettings settings;
  final bool minimized;
  final VoidCallback? onMinimize, onRestore, onClose;
  final ValueChanged<bool>? onPipChanged;
  final PlaybackController? controller;
  @override
  State<WatchScreen> createState() => WatchScreenState();
}

class WatchScreenState extends State<WatchScreen> with WidgetsBindingObserver {
  late final PlaybackController playback =
      widget.controller ?? PlaybackController(settings: widget.settings);
  WebViewController? board;
  BoardTarget? target;
  String? boardError;
  bool loading = false;
  bool fullscreen = false;
  Size _boardSize = const Size(400, 500);
  bool _lastPip = false;
  bool? _configuredPlaying;
  double? _configuredRatio;
  bool get inPip => playback.background.inPip;
  bool get compact => widget.minimized || inPip;
  Future<void> stop() => playback.stop();

  void _playbackChanged() {
    final output = playback.androidVideo;
    final ready =
        playback.active &&
        playback.background.running &&
        output?.value.isInitialized == true &&
        output?.value.isPlaying == true;
    final ratio = output?.value.aspectRatio ?? 16 / 9;
    if (_configuredPlaying != ready || _configuredRatio != ratio) {
      _configuredPlaying = ready;
      _configuredRatio = ratio;
      unawaited(
        playback.background.configure(playing: ready, aspectRatio: ratio),
      );
    }
  }

  void _backgroundChanged() {
    if (!mounted) return;
    _playbackChanged();
    if (_lastPip != inPip) {
      _lastPip = inPip;
      if (!inPip && playback.active) widget.onRestore?.call();
      widget.onPipChanged?.call(inPip);
    }
    setState(() {});
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _showNotice();
    }
  }

  void _showNotice() {
    final notice = playback.background.notice;
    if (notice == null || !mounted) return;
    playback.background.notice = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(notice)));
      }
    });
  }

  void minimize() {
    if (!playback.active ||
        playback.androidVideo?.value.isInitialized != true) {
      return;
    }
    if (fullscreen) setFullscreen(false);
    FocusScope.of(context).unfocus();
    widget.onMinimize?.call();
  }

  void setFullscreen(bool enabled) {
    setState(() => fullscreen = enabled);
    unawaited(setPlaybackFullscreen(enabled));
  }

  void _updateOrientations() {
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        if (!widget.minimized) ...[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      ]),
    );
  }

  @override
  void didUpdateWidget(covariant WatchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.minimized != widget.minimized) _updateOrientations();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    playback.addListener(_playbackChanged);
    playback.background.addListener(_backgroundChanged);
    playback.background.onStop = () {
      unawaited(playback.stop());
      widget.onClose?.call();
    };
    _updateOrientations();
    unawaited(playback.start(widget.channel));
    target = BoardResolver.resolve(
      widget.settings.threads[widget.channel.key] ?? widget.channel.contact,
    );
    if (target != null &&
        !target!.isThread &&
        target!.type == BoardType.other) {
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
    if (state == AppLifecycleState.resumed) _showNotice();
    if (playback.background.shouldStopForLifecycle(state)) {
      unawaited(playback.stop(message: 'バックグラウンドに移動したため停止しました'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    playback.removeListener(_playbackChanged);
    playback.background.removeListener(_backgroundChanged);
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
    if (fullscreen) unawaited(setPlaybackFullscreen(false));
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
        child: PlaybackOverlay(
          hidden: compact,
          top: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  [
                    widget.channel.genre,
                    widget.channel.description,
                    widget.channel.comment,
                  ].where((value) => value.isNotEmpty).join(' / '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ViewerCount(
                    channel: widget.channel,
                    settings: widget.settings,
                  ),
                ],
              ),
            ],
          ),
          bottom: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (playback.active)
                Text(
                  '${playback.snapshot.relays}接続 · 外部送信 ${playback.snapshot.outboundMbps.toStringAsFixed(2)} Mbps · $reachability',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              Row(
                children: [
                  IconButton(
                    tooltip: playback.active ? '視聴を停止' : '視聴を開始',
                    color: Colors.white,
                    icon: Icon(playback.active ? Icons.stop : Icons.play_arrow),
                    onPressed: () => playback.active
                        ? playback.stop()
                        : playback.start(widget.channel),
                  ),
                  BroadcastClock(channel: widget.channel),
                  const Spacer(),
                  if (playback.usesAndroidVideo && widget.onMinimize != null)
                    IconButton(
                      tooltip: 'ミニプレイヤーでチャンネル一覧へ',
                      color: Colors.white,
                      icon: const Icon(Icons.picture_in_picture_alt),
                      onPressed:
                          playback.active &&
                              playback.androidVideo?.value.isInitialized == true
                          ? minimize
                          : null,
                    ),
                  IconButton(
                    tooltip: playback.muted ? 'ミュート解除' : 'ミュート',
                    color: Colors.white,
                    icon: Icon(
                      playback.muted ? Icons.volume_off : Icons.volume_up,
                    ),
                    onPressed: playback.toggleMute,
                  ),
                  IconButton(
                    tooltip: fullscreen ? '全画面を終了' : '全画面',
                    color: Colors.white,
                    icon: Icon(
                      fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    ),
                    onPressed: () => setFullscreen(!fullscreen),
                  ),
                ],
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: PlaybackViewport(
                  inPip: compact,
                  aspectRatio:
                      playback.androidVideo?.value.aspectRatio ??
                      ((playback.player?.state.width ?? 16) /
                          (playback.player?.state.height ?? 9)),
                  onSwipeDown: playback.usesAndroidVideo ? minimize : null,
                  child: playback.usesAndroidVideo
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
              ),
              if (playback.opening)
                const Center(child: CircularProgressIndicator()),
              if (playback.active && playback.simulatorAudioUnavailable)
                const Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Padding(
                        padding: EdgeInsets.all(6),
                        child: Text(
                          'iOSシミュレーターは音声非対応です（音声は実機で確認してください）',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),
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
              if (widget.minimized && !inPip)
                Positioned.fill(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onRestore,
                        ),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: IconButton(
                          tooltip: '視聴を終了',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black54,
                          ),
                          color: Colors.white,
                          icon: const Icon(Icons.close),
                          onPressed: widget.onClose,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        child: IconButton(
                          tooltip: '再生画面に戻る',
                          color: Colors.white,
                          icon: const Icon(Icons.open_in_full),
                          onPressed: widget.onRestore,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
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
      ? ThreadView(
          key: ValueKey(target!.uri.toString()),
          target: target!,
          onNextThread: selectThread,
          onBack: () {
            final home = target!.boardUri;
            setState(() => target = BoardResolver.resolve(home.toString()));
            if (target!.type == BoardType.other) loadBoard(home);
          },
        )
      : target != null && target!.type != BoardType.other
      ? ThreadListView(
          key: ValueKey(target!.boardUri),
          target: target!,
          onSelected: selectThread,
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
    canPop: widget.onClose == null && !fullscreen,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) {
        // dispose runs only after the reverse route animation. Stop output
        // now, before the directory starts reloading behind that animation.
        unawaited(playback.stop());
      } else if (fullscreen) {
        setFullscreen(false);
      } else {
        widget.onClose?.call();
      }
    },
    child: Scaffold(
      backgroundColor: fullscreen ? Colors.black : null,
      appBar: fullscreen || compact
          ? null
          : AppBar(
              leading: widget.onClose == null
                  ? null
                  : BackButton(onPressed: widget.onClose),
              title: Text(widget.channel.name),
            ),
      body: SafeArea(
        top: !fullscreen && !compact,
        bottom: !fullscreen && !compact,
        left: !fullscreen && !compact,
        right: !fullscreen && !compact,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final landscape =
                MediaQuery.orientationOf(context) == Orientation.landscape;
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final videoWidth = fullscreen || compact || !landscape
                ? width
                : width * .6;
            final videoHeight = fullscreen || compact || landscape
                ? height
                : (width * 9 / 16).clamp(0.0, height * .5);
            if (!fullscreen && !compact) {
              _boardSize = Size(
                landscape ? width - videoWidth : width,
                landscape ? height : height - videoHeight,
              );
            }
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
                  left: landscape ? videoWidth : 0,
                  top: landscape ? 0 : videoHeight,
                  right: 0,
                  bottom: 0,
                  child: Offstage(
                    offstage: fullscreen || compact,
                    child: OverflowBox(
                      minWidth: _boardSize.width,
                      maxWidth: _boardSize.width,
                      minHeight: _boardSize.height,
                      maxHeight: _boardSize.height,
                      child: boardView(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
