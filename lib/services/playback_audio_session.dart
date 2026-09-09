import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Prepares iOS audio output before libmpv opens the stream.
class PlaybackAudioSession {
  static const _channel = MethodChannel('peercast_app/playback_audio');
  bool _active = false;

  Future<void> activate() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    await _channel.invokeMethod<void>('activate');
    _active = true;
  }

  Future<void> deactivate() async {
    if (!_active) return;
    await _channel.invokeMethod<void>('deactivate');
    _active = false;
  }
}
