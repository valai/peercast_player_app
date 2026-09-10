import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'peercast_engine.dart';

class PortCheckController extends ChangeNotifier {
  PortCheckController({
    required this.port,
    required this.relays,
    PortListenerBackend? engine,
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
    Stream<List<ConnectivityResult>>? connectivityChanges,
    Future<Directory> Function()? directory,
  }) : engine = engine ?? PeerCastEngine(),
       checkConnectivity =
           checkConnectivity ?? Connectivity().checkConnectivity,
       directory = directory ?? getApplicationSupportDirectory {
    _network = (connectivityChanges ?? Connectivity().onConnectivityChanged)
        .listen((links) {
          if ((starting || listening) && !_wifi(links)) {
            unawaited(stop('Wi-Fi接続が失われたため待受を停止しました'));
          }
        });
  }
  final int port, relays;
  final PortListenerBackend engine;
  final Future<List<ConnectivityResult>> Function() checkConnectivity;
  final Future<Directory> Function() directory;
  late final StreamSubscription<List<ConnectivityResult>> _network;
  Timer? _timer;
  Future<void> _cleanup = Future.value();
  int _generation = 0;
  bool _disposed = false, _polling = false;
  bool starting = false, listening = false;
  String message = '停止中';
  bool _wifi(List<ConnectivityResult> links) =>
      links.contains(ConnectivityResult.wifi) &&
      !links.contains(ConnectivityResult.none);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    final cleanup = stop();
    final ticket = _generation;
    await cleanup;
    if (_disposed || ticket != _generation) return;
    starting = true;
    message = 'ポート $port の待受を開始中…';
    _changed();
    try {
      if (!_wifi(await checkConnectivity())) throw StateError('Wi-Fiに接続してください');
      if (_disposed || ticket != _generation) return;
      final path = await directory();
      if (_disposed || ticket != _generation) return;
      await engine.startListener(path.path, port, relays);
      for (var i = 0; i < 50; i++) {
        if (_disposed || ticket != _generation) return;
        final state = await engine.snapshot();
        if (_disposed || ticket != _generation) return;
        if (!state.running) throw StateError('待受を開始できませんでした。ポートの使用状況を確認してください');
        if (state.listening) {
          starting = false;
          listening = true;
          message = 'ポート $port で待受中';
          _changed();
          _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
            if (_polling || !listening) return;
            _polling = true;
            try {
              final links = await checkConnectivity();
              if (_disposed || ticket != _generation) return;
              if (!_wifi(links)) {
                await stop('Wi-Fi接続が失われたため待受を停止しました');
                return;
              }
              final state = await engine.snapshot();
              if (_disposed || ticket != _generation) return;
              if (!state.running || !state.listening) {
                await stop('ポートの待受が終了しました');
              }
            } catch (_) {
              if (ticket == _generation) await stop('待受状態を確認できませんでした');
            } finally {
              _polling = false;
            }
          });
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw StateError('待受の開始がタイムアウトしました');
    } catch (e) {
      if (!_disposed && ticket == _generation) {
        await stop(e is StateError ? e.message : '$e');
      }
    }
  }

  Future<void> stop([String reason = '停止中']) {
    ++_generation;
    starting = false;
    listening = false;
    _timer?.cancel();
    _timer = null;
    message = reason;
    _changed();
    _cleanup = _cleanup.then((_) async {
      try {
        await engine.stop();
      } catch (_) {
        message = '待受の停止を確認できませんでした。アプリを再起動してください';
        _changed();
      }
    });
    return _cleanup;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_network.cancel());
    unawaited(stop());
    super.dispose();
  }
}
