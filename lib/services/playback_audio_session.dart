import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Prepares iOS audio output before libmpv opens the stream.
class PlaybackAudioSession {
  static const _channel = MethodChannel('peercast_app/playback_audio');
  bool _active = false;

  /// Returns true only when the native iOS build requires silent playback.
  Future<bool> activate() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    final silent = await _channel.invokeMethod<bool>('activate') ?? false;
    _active = !silent;
    return silent;
  }

  Future<void> deactivate() async {
    if (!_active) return;
    await _channel.invokeMethod<void>('deactivate');
    _active = false;
  }
}
