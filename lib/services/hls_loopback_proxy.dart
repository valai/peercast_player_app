import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'windows_mobile_api.dart';

/// Keeps ticket-bearing HLS URLs inside Dart instead of handing them to a player.
class HlsLoopbackProxy {
  HlsLoopbackProxy._(this._server, this._upstream, this._root, this._secret) {
    _subscription = _server.listen((request) => unawaited(_handle(request)));
  }

  final HttpServer _server;
  final HttpClient _upstream;
  final Uri _root;
  final String _secret;
  late final StreamSubscription<HttpRequest> _subscription;
  bool _closed = false;

  static Future<HlsLoopbackProxy> bind(
    WindowsCredentials credentials,
    WindowsSessionStatus status,
  ) async {
    final auto = status.playlists['auto'];
    final parts = auto?.pathSegments;
    if (auto == null ||
        parts == null ||
        parts.length != 4 ||
        parts[0] != 'hls' ||
        parts[1] != status.sessionId ||
        parts[2].isEmpty ||
        parts[3] != 'master.m3u8' ||
        auto.scheme != credentials.baseUrl.scheme ||
        auto.host != credentials.baseUrl.host ||
        auto.port != credentials.baseUrl.port ||
        auto.userInfo.isNotEmpty ||
        auto.hasQuery ||
        auto.hasFragment) {
      throw const WindowsApiException('HLSの応答が正しくありません');
    }
    final root = auto.replace(path: '/hls/${parts[1]}/${parts[2]}/');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final secret = base64Url
        .encode(List<int>.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = false;
    client.findProxy = (_) => 'DIRECT';
    return HlsLoopbackProxy._(server, client, root, secret);
  }

  Uri playlist(WindowsSessionStatus status, String quality) {
    const names = {
      'auto': 'master.m3u8',
      'high': 'high/index.m3u8',
      'medium': 'medium/index.m3u8',
      'low': 'low/index.m3u8',
    };
    final name = names[quality];
    if (name == null || status.playlists[quality] != _root.resolve(name)) {
      throw const WindowsApiException('画質のURLが正しくありません');
    }
    return Uri.parse('http://127.0.0.1:${_server.port}/$_secret/$name');
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (_closed ||
          request.method != 'GET' ||
          request.uri.hasQuery ||
          segments.length < 2 ||
          segments.first != _secret ||
          segments
              .skip(1)
              .any(
                (part) =>
                    part.isEmpty ||
                    part == '.' ||
                    part == '..' ||
                    !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(part),
              ) ||
          !(segments.last.endsWith('.m3u8') || segments.last.endsWith('.ts'))) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final remote = _root.resolve(segments.skip(1).join('/'));
      if (remote.host != _root.host || !remote.path.startsWith(_root.path)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final upstreamRequest = await _upstream
          .getUrl(remote)
          .timeout(const Duration(seconds: 10));
      upstreamRequest.followRedirects = false;
      final upstream = await upstreamRequest.close().timeout(
        const Duration(seconds: 15),
      );
      request.response.statusCode = upstream.statusCode;
      request.response.headers.contentType = upstream.headers.contentType;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      await request.response.addStream(upstream);
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {
        // The player may have closed the request while stopping.
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _upstream.close(force: true);
    await _server.close(force: true);
  }
}
