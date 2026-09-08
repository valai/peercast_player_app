import 'dart:async';

import 'package:flutter/material.dart';

import '../services/board_client.dart';
import '../services/board_resolver.dart';

class ThreadView extends StatefulWidget {
  const ThreadView({super.key, required this.target, this.client});
  final BoardTarget target;
  final BoardClient? client;
  @override
  State<ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<ThreadView> with WidgetsBindingObserver {
  late final BoardClient client = widget.client ?? BoardClient();
  final scroll = ScrollController();
  final name = TextEditingController(),
      mail = TextEditingController(),
      message = TextEditingController();
  final composerGroup = Object();
  String mailBeforeSage = '';
  Timer? timer;
  BoardThread? thread;
  String? error;
  bool loading = false,
      sending = false,
      autoScroll = true,
      foreground = true,
      composing = false;
  int interval = 30;
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
        if (!sending) unawaited(reload());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) scrollRequest++;
    schedule();
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

  Future<void> reload() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final next = await client.fetch(widget.target);
      if (!mounted) return;
      final changed =
          thread == null || thread!.posts.last.number != next.posts.last.number;
      setState(() => thread = next);
      if (autoScroll && changed && foreground) toBottom();
    } catch (e) {
      if (mounted) setState(() => error = '更新失敗: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('書き込みました')));
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
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                thread?.title ?? 'スレッド',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: '更新',
              onPressed: loading ? null : reload,
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
                  }
                },
                icon: const Icon(Icons.edit),
              ),
            ),
          ],
        ),
      ),
      SingleChildScrollView(
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
              items: [0, 15, 30, 60, 120]
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
      if (loading) const LinearProgressIndicator(),
      if (error != null)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 90),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ),
      Expanded(
        child: thread == null
            ? Center(child: Text(loading ? '読み込み中…' : '更新ボタンで再読み込みできます'))
            : Listener(
                // Stop pending automatic scroll steps when the reader interacts.
                onPointerDown: (_) => scrollRequest++,
                onPointerSignal: (_) => scrollRequest++,
                child: ListView.builder(
                  controller: scroll,
                  itemCount: thread!.posts.length,
                  itemBuilder: (context, index) {
                    final post = thread!.posts[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${post.number} · ${post.name} · ${post.date}',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          SelectableText(post.body),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
      if (composing)
        Flexible(
          child: TapRegion(
            groupId: composerGroup,
            onTapOutside: (_) => closeComposer(),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: name,
                            enabled: !sending,
                            decoration: const InputDecoration(
                              labelText: '名前（省略可）',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: mail,
                            enabled: !sending,
                            decoration: const InputDecoration(labelText: 'メール'),
                          ),
                        ),
                      ],
                    ),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: mail,
                      builder: (context, value, _) => CheckboxListTile(
                        title: const Text('sage'),
                        value: value.text.trim() == 'sage',
                        onChanged: sending
                            ? null
                            : (checked) => toggleSage(checked!),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    ),
                    TextField(
                      controller: message,
                      enabled: !sending,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(labelText: '本文'),
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
    ],
  );
}
