import 'package:flutter/material.dart';

/// Shared keyboard accessory, including numeric and multiline input fields.
class KeyboardDismiss extends StatelessWidget {
  const KeyboardDismiss({super.key, required this.child});
  final Widget child;
  static final _accessoryKey = GlobalKey();

  /// The accessory lives outside the Navigator's TapRegionSurface.
  /// Let input panels distinguish its taps from ordinary outside taps.
  static bool isAccessoryTap(Offset position) {
    final box = _accessoryKey.currentContext?.findRenderObject();
    return box is RenderBox &&
        (box.localToGlobal(Offset.zero) & box.size).contains(position);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    const height = 48.0;
    return Overlay.wrap(
      child: Stack(
        children: [
          Positioned.fill(
            child: MediaQuery(
              data: keyboard > 0
                  ? media.copyWith(
                      viewInsets: media.viewInsets.copyWith(
                        bottom: keyboard + height,
                      ),
                    )
                  : media,
              child: child,
            ),
          ),
          if (keyboard > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: keyboard,
              height: height,
              child: Material(
                key: _accessoryKey,
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: '入力を確定してキーボードを閉じる',
                    icon: const Icon(Icons.check),
                    onPressed: () =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
