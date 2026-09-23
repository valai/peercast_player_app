import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/channel.dart';

class WindowsApiException implements Exception {
  const WindowsApiException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => message;
}

class PairPayload {
  const PairPayload(this.baseUrl, this.pairCode, this.expiresAt);
  final Uri baseUrl;
  final String pairCode;
  final DateTime expiresAt;

  static Uri validateBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        !uri.hasPort ||
        uri.port < 1024 ||
        uri.port > 65535 ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Windowsの接続先が正しくありません');
    }
    final parts = uri.host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 ||
        parts.any((part) => part == null || part < 0 || part > 255) ||
        parts[0] != 100 ||
        parts[1]! < 64 ||
        parts[1]! > 127) {
      throw const FormatException('TailscaleのIPv4アドレスではありません');
    }
    return uri.replace(path: '/', query: null, fragment: null);
  }

  factory PairPayload.parse(String raw, {DateTime Function()? now}) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['v'] != 1) throw const FormatException('未対応のQRです');
      final url = validateBaseUrl(data['baseUrl'] as String);
      final code = data['pairCode'] as String;
      final expiry = DateTime.parse(data['expiresAt'] as String).toUtc();
      if (code.isEmpty || expiry.isBefore((now ?? DateTime.now)().toUtc())) {
        throw const FormatException('ペアリングQRの期限が切れています');
      }
      return PairPayload(url, code, expiry);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('ペアリングQRを読み取れませんでした');
    }
  }
}

class WindowsCredentials {
  const WindowsCredentials(this.baseUrl, this.token);
  final Uri baseUrl;
  final String token;
}

class WindowsCredentialStore {
  WindowsCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  static const _key = 'peercast.windows_pairing.v1';
  final FlutterSecureStorage _storage;

  Future<WindowsCredentials?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return WindowsCredentials(
        PairPayload.validateBaseUrl(data['baseUrl'] as String),
        data['token'] as String,
      );
    } catch (_) {
      await delete();
      return null;
    }
  }

  Future<void> write(WindowsCredentials credentials) => _storage.write(
    key: _key,
    value: jsonEncode({
      'baseUrl': credentials.baseUrl.toString(),
      'token': credentials.token,
    }),
  );

  Future<void> delete() => _storage.delete(key: _key);
}

class WindowsSessionStatus {
  const WindowsSessionStatus({
    required this.sessionId,
    required this.channelId,
    required this.state,
    required this.error,
    required this.peerCastOnline,
    required this.relayReachable,
    required this.downstreamRelays,
    required this.relayMessage,
    required this.playlists,
  });
  final String? sessionId, channelId, error;
  final String state, relayMessage;
  final bool peerCastOnline, relayReachable;
  final int downstreamRelays;
  final Map<String, Uri> playlists;

  factory WindowsSessionStatus.fromJson(Map<String, dynamic> data) {
    final raw = data['playlists'] as Map<String, dynamic>?;
    return WindowsSessionStatus(
      sessionId: data['sessionId'] as String?,
      channelId: data['channelId'] as String?,
      state: data['state'] as String? ?? 'idle',
      error: data['error'] as String?,
      peerCastOnline: data['peerCastOnline'] == true,
      relayReachable: data['relayReachable'] == true,
      downstreamRelays: (data['downstreamRelays'] as num?)?.toInt() ?? 0,
      relayMessage: data['relayMessage'] as String? ?? '',
      playlists: {
        if (raw != null)
          for (final entry in raw.entries)
            if (entry.value is String)
              entry.key: Uri.parse(entry.value as String),
      },
    );
  }
}

class WindowsMobileApi {
  WindowsMobileApi(this.credentials, {http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;
  final WindowsCredentials credentials;
  final http.Client _client;
  final bool _ownsClient;

  static Future<WindowsCredentials> pair(
    PairPayload payload, {
    http.Client? client,
  }) async {
    final api = WindowsMobileApi(
      WindowsCredentials(payload.baseUrl, ''),
      client: client,
    );
    try {
      final response = await api._send(
        'POST',
        '/api/v1/pair',
        body: {'pairCode': payload.pairCode},
        authorized: false,
      );
      if (response.statusCode == 401) {
        throw const WindowsApiException(
          'ペアリングQRの期限切れ、または使用済みです',
          statusCode: 401,
        );
      }
      if (response.statusCode != 200) {
        throw WindowsApiException('ペアリングに失敗しました (HTTP ${response.statusCode})');
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['tokenType'] != 'Bearer' ||
          body['token'] is! String ||
          (body['token'] as String).isEmpty) {
        throw const WindowsApiException('ペアリング応答が正しくありません');
      }
      return WindowsCredentials(payload.baseUrl, body['token'] as String);
    } on WindowsApiException {
      rethrow;
    } on SocketException {
      throw const WindowsApiException('Windowsアプリに接続できません。Tailscaleを確認してください');
    } on TimeoutException {
      throw const WindowsApiException('Windowsアプリに接続できません。Tailscaleを確認してください');
    } on http.ClientException {
      throw const WindowsApiException('Windowsアプリに接続できません。Tailscaleを確認してください');
    } finally {
      api.dispose();
    }
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${credentials.token}',
    'Content-Type': 'application/json',
  };

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authorized = true,
  }) async {
    final request = http.Request(method, credentials.baseUrl.resolve(path))
      ..followRedirects = false;
    if (authorized) request.headers.addAll(_headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 10));
    return http.Response.fromStream(streamed)
        .timeout(const Duration(seconds: 10));
  }

  Future<http.Response> _request(Future<http.Response> Function() send) async {
    try {
      final response = await send().timeout(const Duration(seconds: 10));
      if (response.statusCode == 401) {
        throw const WindowsApiException(
          'Windowsとの登録が無効です。再ペアリングしてください',
          statusCode: 401,
        );
      }
      return response;
    } on WindowsApiException {
      rethrow;
    } on SocketException {
      throw const WindowsApiException('Windowsアプリに接続できません。Tailscaleを確認してください');
    } on TimeoutException {
      throw const WindowsApiException('Windowsアプリに接続できません。Tailscaleを確認してください');
    } on http.ClientException {
      throw const WindowsApiException('Windowsアプリに接続できません。Tailscaleを確認してください');
    }
  }

  Future<String> start(Channel channel) async {
    final response = await _request(
      () => _send(
        'POST',
        '/api/v1/sessions',
        body: {'channelId': channel.id, 'tracker': channel.tracker},
      ),
    );
    if (response.statusCode == 409) {
      throw const WindowsApiException(
        'Windowsでは別の番組を視聴中です',
        statusCode: 409,
        code: 'session_busy',
      );
    }
    if (response.statusCode == 422) {
      throw const WindowsApiException(
        '番組IDまたはtrackerが正しくありません',
        statusCode: 422,
      );
    }
    if (response.statusCode != 202) {
      throw WindowsApiException('番組を開始できません (HTTP ${response.statusCode})');
    }
    try {
      return (jsonDecode(response.body) as Map<String, dynamic>)['sessionId']
          as String;
    } catch (_) {
      throw const WindowsApiException('セッション応答が正しくありません');
    }
  }

  Future<WindowsSessionStatus> status() async {
    final response = await _request(
      () => _send('GET', '/api/v1/sessions/current'),
    );
    if (response.statusCode != 200) {
      throw WindowsApiException('状態を取得できません (HTTP ${response.statusCode})');
    }
    try {
      return WindowsSessionStatus.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const WindowsApiException('状態の応答が正しくありません');
    }
  }

  Future<void> stop() async {
    final response = await _request(
      () => _send('DELETE', '/api/v1/sessions/current'),
    );
    if (response.statusCode != 204) {
      throw WindowsApiException(
        'Windowsの視聴を終了できません (HTTP ${response.statusCode})',
      );
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
