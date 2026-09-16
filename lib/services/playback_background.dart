import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One bridge per playback session. Native callbacks never start playback.
class PlaybackBackground extends ChangeNotifier {
  PlaybackBackground({MethodChannel? channel, bool? android})
    : _channel = channel ?? const MethodChannel('peercast/playback'),
      _android = android ?? Platform.isAndroid {
    if (_android) {
      _owner = this;
      _channel.setMethodCallHandler(_event);
    }
  }

  final MethodChannel _channel;
  static PlaybackBackground? _owner;
  final bool _android;
  bool running = false;
  bool pipSupported = false;
  bool inPip = false;
  String? notice;
  VoidCallback? onStop;
  bool shouldStopForLifecycle(AppLifecycleState state) =>
      state == AppLifecycleState.detached ||
      (!running &&
          (state == AppLifecycleState.hidden ||
              state == AppLifecycleState.paused));
  int _generation = 0;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _event(MethodCall call) async {
    if (_disposed) return;
    switch (call.method) {
      case 'pipChanged':
        inPip = call.arguments == true;
      case 'stop':
        onStop?.call();
      case 'serviceLost':
        running = false;
        onStop?.call();
      case 'pipFailed':
        notice = 'PiPに移行できませんでした。端末のPiP許可設定を確認してください';
    }
    _changed();
  }

  Future<void> start(String title) async {
    if (!_android || _disposed) return;
    final ticket = ++_generation;
    try {
      pipSupported = await _channel.invokeMethod<bool>('pipSupported') ?? false;
      if (ticket != _generation || _disposed) return;
      final started =
          await _channel.invokeMethod<bool>('start', title) ?? false;
      if (ticket != _generation || _disposed) return;
      running = started;
      if (!started) notice = 'バックグラウンド再生を開始できませんでした';
    } on PlatformException {
      if (ticket != _generation || _disposed) return;
      running = false;
      notice = 'バックグラウンド再生を開始できませんでした';
    } on MissingPluginException {
      running = false;
    }
    _changed();
  }

  Future<void> configure({
    required bool playing,
    double aspectRatio = 16 / 9,
  }) async {
    if (!_android || _disposed) return;
    try {
      await _channel.invokeMethod<void>('configure', {
        'playing': playing && running,
        'aspectRatio': aspectRatio.isFinite && aspectRatio > 0
            ? aspectRatio
            : 16 / 9,
      });
    } on PlatformException {
      notice = 'PiPの設定に失敗しました';
    } on MissingPluginException {
      // No native backend on unsupported test hosts.
    }
  }

  Future<bool> enterPip() async {
    if (!_android || !running || !pipSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('enterPip') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stop() async {
    ++_generation;
    running = false;
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Native onDestroy also releases the locks.
    } on MissingPluginException {
      // Unsupported test host.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    if (_android && identical(_owner, this)) {
      _owner = null;
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
