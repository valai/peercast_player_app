import 'dart:async';

/// Opening media only queues a load in libmpv. Wait for its clock to advance,
/// including audio-only streams, rather than treating that command as playback.
class PlaybackStartup {
  PlaybackStartup(
    Stream<Duration> positions, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    _subscription = positions.listen((position) {
      if (position > Duration.zero) _finish(true);
    });
    _timer = Timer(timeout, () {
      if (!_result.isCompleted) {
        _result.completeError(TimeoutException('配信を受信しましたが再生を開始できませんでした'));
      }
      cancel();
    });
  }

  final _result = Completer<bool>();
  StreamSubscription<Duration>? _subscription;
  Timer? _timer;
  Future<bool> get ready => _result.future;

  void _finish(bool started) {
    if (!_result.isCompleted) _result.complete(started);
    _timer?.cancel();
    unawaited(_subscription?.cancel());
  }

  void cancel() => _finish(false);
}
