import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/channel.dart';
import 'windows_mobile_api.dart';

class DirectoryResult {
  const DirectoryResult(this.channels, this.errors);
  final List<Channel> channels;
  final Map<String, String> errors;
}

class _HttpFailure implements Exception {
  const _HttpFailure(this.status);
  final int status;
  @override
  String toString() => 'HTTP $status';
}

class ChannelDirectory {
  ChannelDirectory({
    http.Client? client,
    http.Client Function()? clientFactory,
    this.requestTimeout = const Duration(seconds: 15),
    this.retryDelay = const Duration(milliseconds: 300),
    bool Function()? useWindowsForSp,
    WindowsCredentialStore? credentialStore,
    WindowsMobileApi Function(WindowsCredentials)? windowsApiFactory,
  }) : _sharedClient = client,
       _clientFactory = clientFactory ?? http.Client.new,
       _useWindowsForSp = useWindowsForSp ?? (() => false),
       _credentialStore = credentialStore ?? WindowsCredentialStore(),
       _windowsApiFactory = windowsApiFactory ?? WindowsMobileApi.new;
  final http.Client? _sharedClient;
  final http.Client Function() _clientFactory;
  final bool Function() _useWindowsForSp;
  final WindowsCredentialStore _credentialStore;
  final WindowsMobileApi Function(WindowsCredentials) _windowsApiFactory;
  final Duration requestTimeout, retryDelay;
  final _active = <http.Client>{};
  final _cache = <(String, String, bool), List<Channel>>{};
  bool _disposed = false;
  int _generation = 0;

  Future<List<Channel>> _fetch(YellowPage source, Uri uri) async {
    final client = _sharedClient ?? _clientFactory();
    _active.add(client);
    try {
      return await (() async {
        final request = http.Request('GET', uri)..persistentConnection = false;
        final response = await client.send(request);
        if (response.statusCode != 200) throw _HttpFailure(response.statusCode);
        const limit = 4 * 1024 * 1024;
        if ((response.contentLength ?? 0) > limit) {
          throw const FormatException('YPの応答が大きすぎます');
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('YPの応答が大きすぎます');
          }
          bytes.addAll(chunk);
        }
        final body = utf8.decode(bytes);
        final channels = Channel.parse(body, source);
        if (body.trim().isNotEmpty && channels.isEmpty) {
          throw const FormatException('index.txtの形式ではありません');
        }
        return channels;
      })().timeout(requestTimeout);
    } finally {
      _active.remove(client);
      // Closing an owned client also aborts any timed-out response stream.
      if (_sharedClient == null) client.close();
    }
  }

  Future<List<Channel>> _fetchSpViaWindows(YellowPage source) async {
    final credentials = await _credentialStore.read();
    if (credentials == null) {
      throw StateError('Windowsとペアリングしてください');
    }
    final api = _windowsApiFactory(credentials);
    try {
      final body = await api.fetchSpIndex().timeout(requestTimeout);
      final channels = Channel.parse(body, source);
      if (body.trim().isNotEmpty && channels.isEmpty) {
        throw const FormatException('index.txtの形式ではありません');
      }
      return channels;
    } finally {
      api.dispose();
    }
  }

  bool _viaWindows(YellowPage source) =>
      _useWindowsForSp() &&
      source.id == 'sp' &&
      source.url == YellowPage.defaults.first.url;

  bool _retryable(Object error) =>
      error is http.ClientException ||
      error is TimeoutException ||
      error is _HttpFailure && [502, 503, 504].contains(error.status);

  String _message(Object error) {
    if (error is TimeoutException) return '応答がタイムアウトしました';
    if (error is http.ClientException) return '通信が途中で切断されたか、接続できませんでした';
    if (error is FormatException) return error.message;
    if (error is StateError) return error.message;
    return error.toString();
  }

  Future<DirectoryResult> refresh(List<YellowPage> sources) async {
    if (_disposed) return const DirectoryResult([], {});
    final generation = ++_generation;
    final enabled = sources.where((s) => s.enabled).toList();
    final keys = enabled.map((s) => (s.id, s.url, _viaWindows(s))).toSet();
    _cache.removeWhere((key, _) => !keys.contains(key));
    final results = await Future.wait(
      enabled.map((source) async {
        final viaWindows = _viaWindows(source);
        final key = (source.id, source.url, viaWindows);
        try {
          final uri = webUri(source.url);
          if (uri == null) {
            throw const FormatException('HTTP/HTTPSのURLを指定してください');
          }
          for (var attempt = 0; ; attempt++) {
            try {
              final channels = viaWindows
                  ? await _fetchSpViaWindows(source)
                  : await _fetch(source, uri);
              if (!_disposed && generation == _generation) {
                _cache[key] = channels;
              }
              return DirectoryResult(channels, {});
            } catch (e) {
              if (attempt >= 1 || !_retryable(e) || _disposed) rethrow;
              await Future<void>.delayed(retryDelay);
              if (_disposed) rethrow;
            }
          }
        } catch (e) {
          final previous = _cache[key];
          return DirectoryResult(previous ?? [], {
            source.name:
                '取得失敗: ${_message(e)}${previous == null ? '' : '（前回取得した一覧を表示中）'}',
          });
        }
      }),
    );
    return DirectoryResult(
      [for (final r in results) ...r.channels],
      {for (final r in results) ...r.errors},
    );
  }

  void dispose() {
    _disposed = true;
    for (final client in _active.toList()) {
      client.close();
    }
    _active.clear();
    _sharedClient?.close();
    _cache.clear();
  }
}
