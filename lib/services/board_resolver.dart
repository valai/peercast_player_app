import '../models/channel.dart';

enum BoardType { jpnkn, shitaraba, other }

class BoardTarget {
  const BoardTarget(this.uri, this.type, this.isThread);
  final Uri uri;
  final BoardType type;
  final bool isThread;
  String get label => switch (type) {
    BoardType.jpnkn => 'JPNKN',
    BoardType.shitaraba => 'したらば',
    BoardType.other => 'コンタクト',
  };
}

class BoardResolver {
  static BoardTarget? resolve(String value) {
    final uri = webUri(value);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final type = host == 'bbs.jpnkn.com'
        ? BoardType.jpnkn
        : ['jbbs.shitaraba.net', 'jbbs.livedoor.jp'].contains(host)
        ? BoardType.shitaraba
        : BoardType.other;
    final thread = switch (type) {
      BoardType.jpnkn => RegExp(
        r'^/test/read\.cgi/[^/]+/\d+(?:/|$)',
      ).hasMatch(uri.path),
      BoardType.shitaraba => RegExp(
        r'^/bbs/read\.cgi/[^/]+/\d+/\d+(?:/|$)',
      ).hasMatch(uri.path),
      BoardType.other => false,
    };
    return BoardTarget(uri, type, thread);
  }
}
