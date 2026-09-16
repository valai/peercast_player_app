import 'package:html_unescape/html_unescape_small.dart';

Uri? webUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

class YellowPage {
  const YellowPage({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
  });
  final String id, name, url;
  final bool enabled;
  YellowPage copyWith({String? name, String? url, bool? enabled}) => YellowPage(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    enabled: enabled ?? this.enabled,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
  };
  factory YellowPage.fromJson(Map<String, dynamic> j) => YellowPage(
    id: j['id'] as String,
    name: j['name'] as String,
    url: j['url'] as String,
    enabled: j['enabled'] as bool,
  );
  static const defaults = [
    YellowPage(id: 'sp', name: 'SP', url: 'http://bayonet.ddo.jp/sp/index.txt'),
    YellowPage(id: 'pat', name: 'p@', url: 'https://p-at.net/index.txt'),
  ];
}

class Channel {
  const Channel({
    required this.id,
    required this.name,
    required this.sourceId,
    required this.sourceName,
    required this.tracker,
    required this.contact,
    required this.genre,
    required this.description,
    required this.comment,
    required this.format,
    required this.bitrate,
    required this.listeners,
    this.broadcastStartedAt,
  });
  final String id,
      name,
      sourceId,
      sourceName,
      tracker,
      contact,
      genre,
      description,
      comment,
      format;
  final int bitrate, listeners;
  final DateTime? broadcastStartedAt;

  String broadcastDurationLabel({DateTime? now}) {
    final start = broadcastStartedAt;
    if (start == null) return '配信時間: 不明';
    final seconds = (now ?? DateTime.now()).difference(start).inSeconds;
    final elapsed = seconds < 0 ? 0 : seconds;
    return '配信時間: ${elapsed ~/ 3600}:${(elapsed ~/ 60 % 60).toString().padLeft(2, '0')}:${(elapsed % 60).toString().padLeft(2, '0')}';
  }

  static DateTime? _broadcastStart(String value, DateTime now) {
    final match = RegExp(r'^(\d+):(\d{2})(?::(\d{2}))?$')
        .firstMatch(value.trim());
    if (match == null) return null;
    final minutes = int.parse(match[2]!);
    final seconds = int.parse(match[3] ?? '0');
    if (minutes >= 60 || seconds >= 60) return null;
    return now.subtract(
      Duration(hours: int.parse(match[1]!), minutes: minutes, seconds: seconds),
    );
  }

  String get key => '$sourceId:$id';
  bool get isStatus => id == '00000000000000000000000000000000';
  bool get playable =>
      format.toUpperCase() == 'FLV' &&
      tracker.isNotEmpty &&
      id != '00000000000000000000000000000000';
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sourceId': sourceId,
    'sourceName': sourceName,
    'tracker': tracker,
    'contact': contact,
    'genre': genre,
    'description': description,
    'comment': comment,
    'format': format,
    'bitrate': bitrate,
    'listeners': listeners,
    'broadcastStartedAt': broadcastStartedAt?.toIso8601String(),
  };
  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
    id: j['id'] as String,
    name: j['name'] as String,
    sourceId: j['sourceId'] as String,
    sourceName: j['sourceName'] as String,
    tracker: j['tracker'] as String,
    contact: j['contact'] as String,
    genre: j['genre'] as String,
    description: j['description'] as String,
    comment: j['comment'] as String,
    format: j['format'] as String,
    bitrate: j['bitrate'] as int,
    listeners: j['listeners'] as int,
    broadcastStartedAt: DateTime.tryParse(
      j['broadcastStartedAt'] as String? ?? '',
    ),
  );
  static List<Channel> parse(String text, YellowPage source) {
    final unescape = HtmlUnescape();
    final result = <Channel>[];
    final now = DateTime.now();
    final seen = <String>{};
    for (final line in text.replaceFirst('\uFEFF', '').split('\n')) {
      final f = line.trimRight().split('<>');
      if (f.length != 19 || !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(f[1])) {
        continue;
      }
      final id = f[1].toUpperCase();
      if (!seen.add(id)) continue;
      String field(int i) => unescape.convert(f[i]);
      result.add(
        Channel(
          id: id,
          name: field(0),
          sourceId: source.id,
          sourceName: source.name,
          tracker: f[2],
          contact: field(3),
          genre: field(4),
          description: field(5),
          comment: field(17),
          format: f[9],
          bitrate: int.tryParse(f[8]) ?? 0,
          listeners: int.tryParse(f[6]) ?? -1,
          broadcastStartedAt: _broadcastStart(f[15], now),
        ),
      );
    }
    return result;
  }
}
