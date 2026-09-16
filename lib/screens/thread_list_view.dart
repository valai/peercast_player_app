import 'package:flutter/material.dart';

import '../services/board_client.dart';
import '../services/board_resolver.dart';

class ThreadListView extends StatefulWidget {
  const ThreadListView({
    super.key,
    required this.target,
    required this.onSelected,
    this.client,
  });
  final BoardTarget target;
  final ValueChanged<BoardTarget> onSelected;
  final BoardClient? client;
  @override
  State<ThreadListView> createState() => _ThreadListViewState();
}

class _ThreadListViewState extends State<ThreadListView> {
  late final client = widget.client ?? BoardClient();
  List<BoardThreadEntry> entries = [];
  bool loading = false;
  String? error;
  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await client.fetchThreads(widget.target);
      if (mounted) setState(() => entries = result);
    } catch (e) {
      if (mounted) setState(() => error = 'スレッド一覧の取得に失敗しました: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    if (widget.client == null) client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      children: [
        Material(
          color: colors.surface,
          elevation: 2,
          shadowColor: colors.shadow.withValues(alpha: .18),
          surfaceTintColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Icon(Icons.forum_outlined, size: 18, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${widget.target.label} · スレッド一覧',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '掲示板を更新',
                  onPressed: loading ? null : reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
        Expanded(
          child: RefreshIndicator(
            onRefresh: reload,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: entries.isEmpty ? 1 : entries.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                thickness: .5,
                indent: 16,
                endIndent: 16,
                color: colors.outlineVariant.withValues(alpha: .65),
              ),
              itemBuilder: (context, index) {
                if (entries.isEmpty) {
                  return ListTile(
                    title: Text(loading ? '読み込み中…' : 'スレッドはありません'),
                  );
                }
                final entry = entries[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  title: Text(entry.title, style: theme.textTheme.bodyLarge),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 13,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '${entry.count}レス',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colors.onSurfaceVariant.withValues(alpha: .6),
                  ),
                  onTap: () => widget.onSelected(entry.target),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
