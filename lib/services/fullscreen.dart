import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

Future<void> setPlaybackFullscreen(bool enabled) async {
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await const MethodChannel('peercast/display')
            .invokeMethod<void>('setFullscreen', enabled);
        return;
      } on MissingPluginException {
        // Hot reload cannot install the Activity's native channel. Older
        // Android versions can still use Flutter's system UI implementation.
        debugPrint(
          'Fullscreen native channel unavailable; rebuild and restart '
          'the Android app to enable full system-bar control.',
        );
      }
    }
    await SystemChrome.setEnabledSystemUIMode(
      enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  } on PlatformException catch (e) {
    debugPrint('System bars: $e');
  } on MissingPluginException catch (e) {
    debugPrint('System bars unavailable: $e');
  }
}
