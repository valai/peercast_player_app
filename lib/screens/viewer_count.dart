import 'dart:async';

import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../services/app_settings.dart';
import '../services/channel_directory.dart';

class ViewerCount extends StatefulWidget {
  const ViewerCount({
    super.key,
    required this.channel,
    required this.settings,
    this.directory,
  });
  final Channel channel;
  final AppSettings settings;
  final ChannelDirectory? directory;

  @override
  State<ViewerCount> createState() => _ViewerCountState();
}

class _ViewerCountState extends State<ViewerCount> with WidgetsBindingObserver {
  late final directory =
      widget.directory ??
      ChannelDirectory(
        useWindowsForSp: () =>
            widget.settings.playbackSource == PlaybackSource.windows,
      );
  late int listeners = widget.channel.listeners;
  Timer? timer;
  bool fetching = false;
  bool foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    timer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    if (fetching || !foreground) return;
    fetching = true;
    try {
      final result = await directory.refresh(
        widget.settings.sources
            .where((source) => source.id == widget.channel.sourceId)
            .toList(),
      );
      if (!mounted || !foreground) return;
      for (final channel in result.channels) {
        if (channel.key == widget.channel.key) {
          setState(() => listeners = channel.listeners);
          break;
        }
      }
    } finally {
      fetching = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) unawaited(refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    directory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    listeners < 0 ? '視聴者数非公開' : '視聴者数: $listeners人',
    style: const TextStyle(color: Colors.white, fontSize: 12),
  );
}
