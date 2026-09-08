import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:peercast_app/models/channel.dart';
import 'package:peercast_app/services/channel_directory.dart';

import 'widget_test.dart' show row;

class StreamClient extends http.BaseClient {
  StreamClient(this.stream);
  final Stream<List<int>> stream;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.persistentConnection, isFalse);
    return http.StreamedResponse(stream, 200);
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  final source = YellowPage.defaults.first;
  test('受信途中の切断を新しい接続で1回だけ再試行する', () async {
    final clients = <StreamClient>[];
    final directory = ChannelDirectory(
      retryDelay: Duration.zero,
      clientFactory: () {
        final client = StreamClient(
          clients.isEmpty
              ? Stream<List<int>>.error(
                  http.ClientException(
                    'Connection closed while receiving data',
                  ),
                )
              : Stream.value(utf8.encode(row())),
        );
        clients.add(client);
        return client;
      },
    );
    final result = await directory.refresh([source]);
    expect(result.errors, isEmpty);
    expect(result.channels, hasLength(1));
    expect(clients, hasLength(2));
    expect(clients.every((c) => c.closed), isTrue);
    directory.dispose();
  });
  test('失敗時は前回一覧を明示して保持、URL変更では流用しない', () async {
    var fail = false;
    var calls = 0;
    final directory = ChannelDirectory(
      retryDelay: Duration.zero,
      client: MockClient((_) async {
        calls++;
        if (fail) throw http.ClientException('closed');
        return http.Response.bytes(utf8.encode(row()), 200);
      }),
    );
    await directory.refresh([source]);
    fail = true;
    final failed = await directory.refresh([source]);
    expect(calls, 3);
    expect(failed.channels, hasLength(1));
    expect(failed.errors[source.name], contains('前回取得した一覧'));
    expect(
      (await directory.refresh([
        source.copyWith(url: 'https://example.com/index.txt'),
      ])).channels,
      isEmpty,
    );
    directory.dispose();
  });
  test('正常な空一覧は古いキャッシュを消し、形式エラーは再試行しない', () async {
    var response = row();
    var calls = 0;
    final directory = ChannelDirectory(
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes(utf8.encode(response), 200);
      }),
    );
    await directory.refresh([source]);
    response = '';
    expect((await directory.refresh([source])).channels, isEmpty);
    response = '<html>error</html>';
    final failed = await directory.refresh([source]);
    expect(failed.channels, isEmpty);
    expect(failed.errors, isNotEmpty);
    expect(calls, 3);
    directory.dispose();
  });
  test('タイムアウト時も各クライアントを閉じ、再試行回数を制限する', () async {
    final clients = <StreamClient>[];
    final streams = <StreamController<List<int>>>[];
    final directory = ChannelDirectory(
      requestTimeout: const Duration(milliseconds: 10),
      retryDelay: Duration.zero,
      clientFactory: () {
        final stream = StreamController<List<int>>();
        streams.add(stream);
        final client = StreamClient(stream.stream);
        clients.add(client);
        return client;
      },
    );
    final result = await directory.refresh([source]);
    expect(result.errors[source.name], contains('タイムアウト'));
    expect(clients, hasLength(2));
    expect(clients.every((c) => c.closed), isTrue);
    for (final stream in streams) {
      await stream.close();
    }
    directory.dispose();
  });
}
