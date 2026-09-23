import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:peercast_app/models/channel.dart';
import 'package:peercast_app/services/hls_loopback_proxy.dart';
import 'package:peercast_app/services/windows_mobile_api.dart';

const channel = Channel(
  id: '0123456789ABCDEF0123456789ABCDEF',
  name: 'test',
  sourceId: 'sp',
  sourceName: 'SP',
  tracker: 'example.net:7144',
  contact: '',
  genre: '',
  description: '',
  comment: '',
  format: 'FLV',
  bitrate: 500,
  listeners: 1,
);

void main() {
  test('QRは版・期限・Tailscaleアドレスを検証する', () {
    final now = DateTime.utc(2026, 9, 23, 12);
    String payload(String url, {int version = 1, String? expiry}) =>
        jsonEncode({
          'v': version,
          'baseUrl': url,
          'pairCode': 'one-time',
          'expiresAt': expiry ?? '2026-09-23T12:05:00Z',
        });
    expect(
      PairPayload.parse(
        payload('http://100.101.102.103:17444'),
        now: () => now,
      ).baseUrl.host,
      '100.101.102.103',
    );
    expect(
      () =>
          PairPayload.parse(payload('http://127.0.0.1:17444'), now: () => now),
      throwsFormatException,
    );
    expect(
      () => PairPayload.parse(
        payload('http://100.128.1.2:17444'),
        now: () => now,
      ),
      throwsFormatException,
    );
    expect(
      () => PairPayload.parse(
        payload('http://100.101.102.103:17444', version: 2),
        now: () => now,
      ),
      throwsFormatException,
    );
    expect(
      () => PairPayload.parse(
        payload('http://100.101.102.103:17444', expiry: '2026-09-23T11:59:59Z'),
        now: () => now,
      ),
      throwsFormatException,
    );
  });

  test('ペアリング・開始・状態・終了でAPIの認証契約を守る', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      final authorization = request.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'authorization')
          .map((entry) => entry.value)
          .firstOrNull;
      if (request.url.path == '/api/v1/pair') {
        expect(jsonDecode(request.body)['pairCode'], 'one-time');
        expect(authorization, isNull);
        return http.Response('{"token":"secret","tokenType":"Bearer"}', 200);
      }
      expect(authorization, 'Bearer secret');
      if (request.method == 'POST') {
        expect(jsonDecode(request.body), {
          'channelId': channel.id,
          'tracker': channel.tracker,
        });
        return http.Response('{"sessionId":"session","state":"starting"}', 202);
      }
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'sessionId': 'session',
            'channelId': channel.id,
            'state': 'ready',
            'peerCastOnline': true,
            'relayReachable': false,
            'downstreamRelays': 0,
            'relayMessage': 'リレー待受不可',
            'playlists': {
              'auto':
                  'http://100.101.102.103:17444/hls/session/ticket/master.m3u8',
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('', 204);
    });
    final payload = PairPayload.parse(
      jsonEncode({
        'v': 1,
        'baseUrl': 'http://100.101.102.103:17444',
        'pairCode': 'one-time',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 1))
            .toIso8601String(),
      }),
    );
    final credentials = await WindowsMobileApi.pair(payload, client: client);
    final api = WindowsMobileApi(credentials, client: client);
    expect(await api.start(channel), 'session');
    final status = await api.status();
    expect(status.state, 'ready');
    expect(status.relayReachable, false);
    await api.stop();
    expect(requests, [
      'POST /api/v1/pair',
      'POST /api/v1/sessions',
      'GET /api/v1/sessions/current',
      'DELETE /api/v1/sessions/current',
    ]);
  });

  test('競合と認証失効を区別して返す', () async {
    final credentials = WindowsCredentials(
      Uri.parse('http://100.101.102.103:17444'),
      'secret',
    );
    final busy = WindowsMobileApi(
      credentials,
      client: MockClient(
        (_) async => http.Response('{"error":"session_busy"}', 409),
      ),
    );
    await expectLater(
      busy.start(channel),
      throwsA(
        isA<WindowsApiException>().having(
          (e) => e.statusCode,
          'statusCode',
          409,
        ),
      ),
    );
    final revoked = WindowsMobileApi(
      credentials,
      client: MockClient((_) async => http.Response('', 401)),
    );
    await expectLater(
      revoked.status(),
      throwsA(
        isA<WindowsApiException>().having(
          (e) => e.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
  });

  test('HLS中継は相対参照を保ち、認証URLをプレイヤーへ渡さない', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    final subscription = upstream.listen((request) async {
      paths.add(request.uri.path);
      request.response.headers.contentType = ContentType.parse(
        request.uri.path.endsWith('.ts')
            ? 'video/mp2t'
            : 'application/vnd.apple.mpegurl',
      );
      request.response.write(switch (request.uri.path) {
        '/hls/session/ticket/master.m3u8' => '#EXTM3U\nhigh/index.m3u8\n',
        '/hls/session/ticket/high/index.m3u8' => '#EXTM3U\nsegment0.ts\n',
        '/hls/session/ticket/high/segment0.ts' => 'segment',
        _ => 'missing',
      });
      await request.response.close();
    });
    final base = Uri.parse('http://127.0.0.1:${upstream.port}');
    final status = WindowsSessionStatus.fromJson({
      'sessionId': 'session',
      'channelId': channel.id,
      'state': 'ready',
      'playlists': {
        'auto': '$base/hls/session/ticket/master.m3u8',
        'high': '$base/hls/session/ticket/high/index.m3u8',
      },
    });
    final proxy = await HlsLoopbackProxy.bind(
      WindowsCredentials(base, 'secret'),
      status,
    );
    try {
      final master = proxy.playlist(status, 'auto');
      expect(master.host, '127.0.0.1');
      expect(master.toString(), isNot(contains('ticket')));
      final masterBody = (await http.get(master)).body;
      final variant = master.resolve(masterBody.trim().split('\n').last);
      final variantBody = (await http.get(variant)).body;
      final segment = variant.resolve(variantBody.trim().split('\n').last);
      expect((await http.get(segment)).body, 'segment');
      expect(paths, [
        '/hls/session/ticket/master.m3u8',
        '/hls/session/ticket/high/index.m3u8',
        '/hls/session/ticket/high/segment0.ts',
      ]);
      expect(
        (await http.get(master.replace(path: '/wrong/master.m3u8'))).statusCode,
        404,
      );
    } finally {
      await proxy.close();
      await subscription.cancel();
      await upstream.close(force: true);
    }
  });
}
