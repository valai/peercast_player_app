import 'dart:async';

import 'package:flutter/material.dart';

class PlaybackOverlay extends StatefulWidget {
  const PlaybackOverlay({
    super.key,
    required this.child,
    required this.top,
    required this.bottom,
    this.hidden = false,
  });
  final Widget child;
  final Widget top;
  final Widget bottom;
  final bool hidden;
  @override
  State<PlaybackOverlay> createState() => _PlaybackOverlayState();
}

class _PlaybackOverlayState extends State<PlaybackOverlay> {
  Timer? _timer;
  bool _visible = true;
  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _toggle() {
    _timer?.cancel();
    setState(() => _visible = !_visible);
    if (_visible) _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _panel(Widget child, {required bool top}) => IgnorePointer(
    ignoring: !_visible || widget.hidden,
    child: AnimatedOpacity(
      opacity: _visible && !widget.hidden ? 1 : 0,
      duration: _visible ? const Duration(milliseconds: 200) : Duration.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [Color(0xCC000000), Colors.transparent],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, top ? 8 : 20, 12, top ? 20 : 0),
          child: SafeArea(top: top, bottom: !top, child: child),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      if (_visible) _timer?.cancel();
    },
    onPointerUp: (_) {
      if (_visible) _restartTimer();
    },
    onPointerCancel: (_) {
      if (_visible) _restartTimer();
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (!widget.hidden)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _panel(widget.top, top: true),
            ),
          if (!widget.hidden)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _panel(widget.bottom, top: false),
            ),
        ],
      ),
    ),
  );
}
