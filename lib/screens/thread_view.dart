import 'dart:async';

import 'package:flutter/material.dart';

import '../services/board_client.dart';
import 'keyboard_dismiss.dart';
import 'thread_post_text.dart';
import 'thread_web_view.dart';
import '../services/board_resolver.dart';

class ThreadView extends StatefulWidget {
  const ThreadView({super.key, required this.target, this.client, this.onBack});
  final BoardTarget target;
  final BoardClient? client;
  final VoidCallback? onBack;
  @override
  State<ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<ThreadView> with WidgetsBindingObserver {
  late final BoardClient client = widget.client ?? BoardClient();
  final scroll = ScrollController();
  final name = TextEditingController(),
      mail = TextEditingController(text: 'sage'),
      message = TextEditingController();
  final composerGroup = Object();
  String mailBeforeSage = '';
  Timer? timer;
  BoardThread? thread;
  String? error;
  Uri? openedUrl;
  Set<int> newPostNumbers = {};
  bool backgroundLoading = false;
  bool loading = false,
      sending = false,
      autoScroll = true,
      foreground = true,
      composing = false;
  int interval = 7;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(reload());
    schedule();
  }

  void schedule() {
    timer?.cancel();
    if (interval > 0 && foreground) {
      timer = Timer.periodic(Duration(seconds: interval), (_) {
        if (!sending) unawaited(reload(automatic: true));
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) scrollRequest++;
    schedule();
  }

  @override
  void didChangeMetrics() {
    if (composing) toBottom();
  }

  int scrollRequest = 0;
  void toBottom() {
    final request = ++scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Lazy lists estimate the height of unseen responses. Recheck after each
      // layout so long, variable-height threads actually reach the last reply.
      for (var attempt = 0; attempt < 20; attempt++) {
        if (!mounted || !scroll.hasClients || request != scrollRequest) return;
        final end = scroll.position.maxScrollExtent;
        if ((end - scroll.offset).abs() < 1) return;
        await scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
        await WidgetsBinding.instance.endOfFrame;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> reload({bool automatic = false}) async {
    if (loading) return;
    final previous = thread;
    final previousNumbers = previous?.posts.map((post) => post.number).toSet();

    final request = scrollRequest;
    loading = true;
    backgroundLoading = automatic;
    if (!automatic || newPostNumbers.isNotEmpty || error != null) {
      setState(() {
        if (automatic) newPostNumbers = {};
        error = null;
      });
    }
    try {
      final next = await client.fetch(widget.target);
      if (!mounted) return;
      final added = previousNumbers == null
          ? <int>{}
          : next.posts
                .where((post) => !previousNumbers.contains(post.number))
                .map((post) => post.number)
                .toSet();
      if (!_sameThread(previous, next)) {
        setState(() {
          thread = next;
          newPostNumbers = {...newPostNumbers, ...added};
        });
      }
      // Follow new replies on both manual and periodic refreshes when enabled.
      if (autoScroll &&
          (previous == null || added.isNotEmpty) &&
          foreground &&
          request == scrollRequest) {
        toBottom();
      }
    } catch (e) {
      if (mounted) setState(() => error = '更新失敗: $e');
    } finally {
      if (mounted) {
        if (automatic) {
          loading = false;
        } else {
          setState(() => loading = false);
        }
      }
    }
  }

  bool _sameThread(BoardThread? previous, BoardThread next) {
    if (identical(previous, next)) return true;
    if (previous == null ||
        previous.title != next.title ||
        previous.posts.length != next.posts.length) {
      return false;
    }
    for (var i = 0; i < next.posts.length; i++) {
      final a = previous.posts[i];
      final b = next.posts[i];
      if (a.number != b.number ||
          a.name != b.name ||
          a.mail != b.mail ||
          a.date != b.date ||
          a.body != b.body) {
        return false;
      }
    }
    return true;
  }

  Future<void> replyTo(int number) async {
    if (sending) return;
    final reply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('レス $number'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('返信'),
          ),
        ],
      ),
    );
    if (!mounted || reply != true || sending) return;
    final prefix = '>>$number\n';
    message.value = TextEditingValue(
      text: prefix + message.text,
      selection: TextSelection.collapsed(offset: prefix.length),
    );
    setState(() => composing = true);
  }

  void openUrl(Uri url) {
    closeComposer();
    scrollRequest++;
    setState(() => openedUrl = url);
  }

  void closeComposer() {
    if (!composing) return;
    FocusScope.of(context).unfocus();
    setState(() => composing = false);
  }

  void toggleSage(bool enabled) {
    if (enabled) {
      mailBeforeSage = mail.text;
      mail.text = 'sage';
    } else {
      mail.text = mailBeforeSage.trim() == 'sage' ? '' : mailBeforeSage;
    }
  }

  Future<void> submit() async {
    if (sending || message.text.trim().isEmpty) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await client.post(widget.target, name.text, mail.text, message.text);
      if (!mounted) return;
      message.clear();
      setState(() => composing = false);
      await reload();
    } catch (e) {
      if (mounted) setState(() => error = '書き込み失敗: $e');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (widget.client == null) client.dispose();
    scroll.dispose();
    name.dispose();
    mail.dispose();
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      // Keep the thread and its scroll position mounted while browsing.
      buildThread(context),
      if (openedUrl != null)
        ThreadWebView(
          key: ValueKey(openedUrl),
          url: openedUrl!,
          onClose: () => setState(() => openedUrl = null),
        ),
    ],
  );

  Widget buildThread(BuildContext context) => ColoredBox(
    color: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF242424)
        : const Color(0xFFF3F3F3),
    child: LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            shape: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      if (widget.onBack != null)
                        IconButton(
                          tooltip: 'スレッド一覧に戻る',
                          onPressed: widget.onBack,
                          icon: const Icon(Icons.arrow_back),
                        ),
                      Expanded(
                        child: Text(
                          thread?.title ?? 'スレッド',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '更新',
                        onPressed: loading && !backgroundLoading
                            ? null
                            : reload,
                        icon: const Icon(Icons.refresh),
                      ),
                      TapRegion(
                        groupId: composerGroup,
                        child: IconButton(
                          tooltip: '書き込み',
                          onPressed: () {
                            if (composing) {
                              closeComposer();
                            } else {
                              setState(() => composing = true);
                              toBottom();
                            }
                          },
                          icon: const Icon(Icons.edit),
                        ),
                      ),
                    ],
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('オートスクロール'),
                        selected: autoScroll,
                        onSelected: (v) {
                          setState(() => autoScroll = v);
                          if (v) {
                            toBottom();
                          } else {
                            scrollRequest++;
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      const Text('自動更新: '),
                      DropdownButton<int>(
                        value: interval,
                        items: [0, 7, 15, 30]
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text(v == 0 ? 'OFF' : '$v秒'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          setState(() => interval = v!);
                          schedule();
                        },
                      ),
                      IconButton(
                        tooltip: '最新レスへ',
                        onPressed: toBottom,
                        icon: const Icon(Icons.vertical_align_bottom),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, available) => Column(
                children: [
                  if (loading && !backgroundLoading)
                    const LinearProgressIndicator(),
                  Expanded(
                    // Preserve the list when the composer and loading bar change together.
                    key: const ValueKey('thread-post-list'),
                    child: TapRegion(
                      groupId: composerGroup,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: closeComposer,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            thread == null
                                ? Center(
                                    child: Text(
                                      loading ? '読み込み中…' : '更新ボタンで再読み込みできます',
                                    ),
                                  )
                                : Listener(
                                    // Stop pending automatic scroll steps when the reader interacts.
                                    onPointerDown: (_) => scrollRequest++,
                                    onPointerSignal: (_) => scrollRequest++,
                                    child: ListView.builder(
                                      padding: EdgeInsets.zero,
                                      controller: scroll,
                                      itemCount: thread!.posts.length,
                                      itemBuilder: (context, index) {
                                        final post = thread!.posts[index];
                                        final sage =
                                            post.mail.trim().toLowerCase() ==
                                            'sage';
                                        final dark =
                                            Theme.of(context).brightness ==
                                            Brightness.dark;
                                        final nameColor = sage
                                            ? (dark
                                                  ? const Color(0xFFE6A0E6)
                                                  : const Color(0xFF800080))
                                            : (dark
                                                  ? const Color(0xFF81C784)
                                                  : const Color(0xFF008000));
                                        return ColoredBox(
                                          key: ValueKey(post.number),
                                          color:
                                              newPostNumbers.contains(
                                                post.number,
                                              )
                                              ? (dark
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .primaryContainer
                                                    : const Color(0xFFE3F2FD))
                                              : Colors.transparent,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              border: Border(
                                                top: BorderSide(
                                                  color: Theme.of(context)
                                                      .dividerColor
                                                      .withValues(alpha: .12),
                                                ),
                                                bottom: BorderSide(
                                                  color: Theme.of(context)
                                                      .dividerColor
                                                      .withValues(alpha: .12),
                                                ),
                                              ),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 8,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text.rich(
                                                  TextSpan(
                                                    children: [
                                                      WidgetSpan(
                                                        alignment:
                                                            PlaceholderAlignment
                                                                .baseline,
                                                        baseline: TextBaseline
                                                            .alphabetic,
                                                        child: InkWell(
                                                          key: ValueKey(
                                                            'reply-${post.number}',
                                                          ),
                                                          onTap: sending
                                                              ? null
                                                              : () => replyTo(
                                                                  post.number,
                                                                ),
                                                          child: Text(
                                                            '${post.number}',
                                                            style: TextStyle(
                                                              color: dark
                                                                  ? const Color(
                                                                      0xFF90CAF9,
                                                                    )
                                                                  : const Color(
                                                                      0xFF0000FF,
                                                                    ),
                                                              decoration:
                                                                  TextDecoration
                                                                      .underline,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      const TextSpan(
                                                        text: ' : ',
                                                      ),
                                                      TextSpan(
                                                        text: post.name,
                                                        style: TextStyle(
                                                          color: nameColor,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                      TextSpan(
                                                        text:
                                                            ' [${sage ? 'sage' : ''}]',
                                                        style: TextStyle(
                                                          color: nameColor,
                                                        ),
                                                      ),
                                                      TextSpan(
                                                        text: ' ${post.date}',
                                                      ),
                                                    ],
                                                  ),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .labelSmall
                                                      ?.copyWith(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 8,
                                                        top: 4,
                                                      ),
                                                  child: ThreadPostText(
                                                    post.body,
                                                    onTap: closeComposer,
                                                    onOpenUrl: openUrl,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                            if (error != null)
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 0,
                                child: Material(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .errorContainer,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 90,
                                    ),
                                    child: SingleChildScrollView(
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Text(error!),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (composing)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: available.maxHeight * .65,
                      ),
                      child: TapRegion(
                        groupId: composerGroup,
                        onTapOutside: (event) {
                          if (!KeyboardDismiss.isAccessoryTap(event.position)) {
                            closeComposer();
                          }
                        },
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          shape: Border(
                            top: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: name,
                                          onTapOutside: (_) =>
                                              FocusScope.of(context).unfocus(),
                                          enabled: !sending,
                                          decoration: const InputDecoration(
                                            labelText: '名前（省略可）',
                                            isDense: true,
                                            contentPadding:
                                                EdgeInsets.symmetric(
                                                  vertical: 6,
                                                ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextField(
                                          controller: mail,
                                          onTapOutside: (_) =>
                                              FocusScope.of(context).unfocus(),
                                          enabled: !sending,
                                          decoration: const InputDecoration(
                                            labelText: 'メール',
                                            isDense: true,
                                            contentPadding:
                                                EdgeInsets.symmetric(
                                                  vertical: 6,
                                                ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  ValueListenableBuilder<TextEditingValue>(
                                    valueListenable: mail,
                                    builder: (context, value, _) =>
                                        CheckboxListTile(
                                          title: const Text('sage'),
                                          value: value.text.trim() == 'sage',
                                          onChanged: sending
                                              ? null
                                              : (checked) =>
                                                    toggleSage(checked!),
                                          controlAffinity:
                                              ListTileControlAffinity.leading,
                                          contentPadding: EdgeInsets.zero,
                                          dense: true,
                                          visualDensity: VisualDensity.compact,
                                          minVerticalPadding: 0,
                                        ),
                                  ),
                                  TextField(
                                    controller: message,
                                    onTapAlwaysCalled: true,
                                    onTap: () {
                                      if (View.of(context).viewInsets.bottom >
                                          0) {
                                        WidgetsBinding.instance
                                            .addPostFrameCallback((_) {
                                              if (mounted) {
                                                FocusScope.of(context)
                                                    .unfocus();
                                              }
                                            });
                                      }
                                    },
                                    onTapOutside: (_) =>
                                        FocusScope.of(context).unfocus(),
                                    enabled: !sending,
                                    minLines: 2,
                                    maxLines: 4,
                                    decoration: const InputDecoration(
                                      labelText: '本文',
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        vertical: 6,
                                      ),
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: FilledButton(
                                      onPressed: sending ? null : submit,
                                      child: Text(sending ? '送信中…' : '書き込む'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
