import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/channel.dart';

class DirectoryResult {
  const DirectoryResult(this.channels, this.errors);
  final List<Channel> channels;
  final Map<String, String> errors;
}

class ChannelDirectory {
  ChannelDirectory({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  Future<DirectoryResult> refresh(List<YellowPage> sources) async {
    final results = await Future.wait(
      sources.where((s) => s.enabled).map((source) async {
        try {
          final uri = webUri(source.url);
          if (uri == null) {
            throw const FormatException('HTTP/HTTPSのURLを指定してください');
          }
          final response = await _client
              .get(uri)
              .timeout(const Duration(seconds: 15));
          if (response.statusCode != 200) {
            throw Exception('HTTP ${response.statusCode}');
          }
          if (response.bodyBytes.length > 4 * 1024 * 1024) {
            throw const FormatException('YPの応答が大きすぎます');
          }
          final body = utf8.decode(response.bodyBytes);
          final channels = Channel.parse(body, source);
          if (body.trim().isNotEmpty && channels.isEmpty) {
            throw const FormatException('index.txtの形式ではありません');
          }
          return DirectoryResult(channels, {});
        } catch (e) {
          return DirectoryResult([], {source.name: '取得失敗: $e'});
        }
      }),
    );
    return DirectoryResult(
      [for (final r in results) ...r.channels],
      {for (final r in results) ...r.errors},
    );
  }

  void dispose() => _client.close();
}
