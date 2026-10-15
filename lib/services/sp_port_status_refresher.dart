import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'peercast_engine.dart';

/// Refreshes SP's address-specific port status before its channel list is read.
/// SP calculates the displayed check result when its home page is requested,
/// so the local listener must be active for the duration of that request.
class SpPortStatusRefresher {
  SpPortStatusRefresher({
    PortListenerBackend? engine,
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
    Future<Directory> Function()? directory,
    http.Client Function()? clientFactory,
    this.listenerTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 12),
  }) : engine = engine ?? PeerCastEngine(),
       checkConnectivity =
           checkConnectivity ?? Connectivity().checkConnectivity,
       directory = directory ?? getApplicationSupportDirectory,
       clientFactory = clientFactory ?? http.Client.new;

  static final _spHome = Uri.parse('http://bayonet.ddo.jp/sp/');

  final PortListenerBackend engine;
  final Future<List<ConnectivityResult>> Function() checkConnectivity;
  final Future<Directory> Function() directory;
  final http.Client Function() clientFactory;
  final Duration listenerTimeout, requestTimeout;
  Future<bool>? _inFlight;
  http.Client? _activeClient;
  bool _disposed = false;

  Future<bool> refresh({required int port, required int relays}) {
    if (_disposed) return Future.value(false);
    final pending = _inFlight;
    if (pending != null) return pending;

    final request = _refresh(port: port, relays: relays);
    _inFlight = request;
    return request.whenComplete(() {
      if (identical(_inFlight, request)) _inFlight = null;
    });
  }

  Future<bool> _refresh({required int port, required int relays}) async {
    var attemptedStart = false;
    http.Client? client;
    try {
      final links = await checkConnectivity();
      if (!links.contains(ConnectivityResult.wifi) ||
          links.contains(ConnectivityResult.none) ||
          _disposed) {
        return false;
      }

      final supportDirectory = await directory();
      if (_disposed) return false;
      attemptedStart = true;
      await engine.startListener(supportDirectory.path, port, relays);

      final deadline = DateTime.now().add(listenerTimeout);
      var listening = false;
      while (!_disposed && DateTime.now().isBefore(deadline)) {
        final state = await engine.snapshot();
        if (!state.running) return false;
        if (state.listening) {
          listening = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!listening || _disposed) return false;

      client = clientFactory();
      _activeClient = client;
      final request = http.Request('GET', _spHome)
        ..followRedirects = false
        ..persistentConnection = false
        ..headers['Cache-Control'] = 'no-cache';
      final statusCode = await _requestPage(
        client,
        request,
      ).timeout(requestTimeout);
      return statusCode == HttpStatus.ok;
    } catch (_) {
      // Port checking is best effort. A failed preflight must not block YP
      // retrieval; SP will continue to report its own current result.
      return false;
    } finally {
      if (attemptedStart) {
        try {
          await engine.stop();
        } catch (_) {
          // The next engine start performs its own cleanup and validation.
        }
      }
      client?.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  Future<int> _requestPage(http.Client client, http.Request request) async {
    final response = await client.send(request);
    await response.stream.drain<void>();
    return response.statusCode;
  }

  void dispose() {
    _disposed = true;
    _activeClient?.close();
    unawaited(engine.stop());
  }
}
