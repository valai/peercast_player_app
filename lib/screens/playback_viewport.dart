import 'package:flutter/material.dart';

/// Keeps the video transform separate from the playback controls.
class PlaybackViewport extends StatefulWidget {
  const PlaybackViewport({
    super.key,
    required this.child,
    this.inPip = false,
    this.onSwipeDown,
    this.aspectRatio,
  });

  final Widget child;
  final bool inPip;
  final VoidCallback? onSwipeDown;
  final double? aspectRatio;

  @override
  State<PlaybackViewport> createState() => _PlaybackViewportState();
}

class _PlaybackViewportState extends State<PlaybackViewport> {
  double _scale = 1, _startScale = 1;
  Offset _offset = Offset.zero, _anchor = Offset.zero;
  Offset? _down;
  bool _multiple = false;
  final Set<int> _pointers = {};

  Offset _clamp(Offset value, Size size) {
    final ratio = widget.aspectRatio;
    final image = ratio != null && ratio.isFinite && ratio > 0
        ? applyBoxFit(BoxFit.contain, Size(ratio, 1), size).destination
        : size;
    final maxX = ((image.width * _scale - size.width) / 2).clamp(
      0.0,
      double.infinity,
    );
    final maxY = ((image.height * _scale - size.height) / 2).clamp(
      0.0,
      double.infinity,
    );
    return Offset(value.dx.clamp(-maxX, maxX), value.dy.clamp(-maxY, maxY));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (!widget.inPip) _offset = _clamp(_offset, size);
      return Listener(
        onPointerDown: (event) {
          if (_pointers.isEmpty) {
            _down = event.localPosition;
            _multiple = false;
          }
          _pointers.add(event.pointer);
          if (_pointers.length > 1) _multiple = true;
        },
        onPointerCancel: (event) {
          _pointers.remove(event.pointer);
          _down = null;
        },
        onPointerUp: (event) {
          _pointers.remove(event.pointer);
          if (_pointers.isEmpty &&
              !_multiple &&
              _down != null &&
              !widget.inPip) {
            final delta = event.localPosition - _down!;
            if (delta.dy >= 64 && delta.dy > delta.dx.abs()) {
              widget.onSwipeDown?.call();
            }
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (details) {
            _startScale = _scale;
            _anchor =
                (details.localFocalPoint - size.center(Offset.zero) - _offset) /
                _scale;
          },
          onScaleUpdate: (details) {
            if (widget.inPip || details.pointerCount < 2) return;
            setState(() {
              _scale = (_startScale * details.scale).clamp(1.0, 4.0);
              _offset = _clamp(
                details.localFocalPoint -
                    size.center(Offset.zero) -
                    _anchor * _scale,
                size,
              );
            });
          },
          child: ClipRect(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translateByDouble(
                  widget.inPip ? 0 : _offset.dx,
                  widget.inPip ? 0 : _offset.dy,
                  0,
                  1,
                )
                ..scaleByDouble(
                  widget.inPip ? 1 : _scale,
                  widget.inPip ? 1 : _scale,
                  1,
                  1,
                ),
              child: widget.child,
            ),
          ),
        ),
      );
    },
  );
}
