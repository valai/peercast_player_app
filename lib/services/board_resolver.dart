import '../models/channel.dart';

enum BoardType { jpnkn, shitaraba, dmdbs, komokomo, other }

class BoardTarget {
  const BoardTarget(this.uri, this.type, this.isThread);
  final Uri uri;
  final BoardType type;
  final bool isThread;
  Uri endpoint(String path) => Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  );
  String get pathPrefix => type == BoardType.dmdbs ? '/kizuna' : '';
  List<String> get threadParts =>
      type == BoardType.dmdbs ? uri.pathSegments.sublist(1) : uri.pathSegments;
  Uri get boardUri {
    if (!isThread) {
      return endpoint('${uri.path.replaceFirst(RegExp(r'/+$'), '')}/');
    }
    final p = threadParts;
    return endpoint(
      type == BoardType.shitaraba
          ? '/${p[2]}/${p[3]}/'
          : '$pathPrefix/${p[2]}/',
    );
  }

  BoardTarget threadTarget(String key) {
    final home = boardUri.pathSegments.where((p) => p.isNotEmpty).toList();
    final path = type == BoardType.shitaraba
        ? '/bbs/read.cgi/${home[0]}/${home[1]}/$key/'
        : '$pathPrefix/test/read.cgi/${home.last}/$key/';
    return BoardTarget(endpoint(path), type, true);
  }

  String get threadKey => threadParts[type == BoardType.shitaraba ? 4 : 3];
  String get label => switch (type) {
    BoardType.jpnkn => 'JPNKN',
    BoardType.shitaraba => 'したらば',
    BoardType.dmdbs => 'DMDBS',
    BoardType.komokomo => 'こもこも',
    BoardType.other => 'コンタクト',
  };
}

class BoardResolver {
  static BoardTarget? resolve(String value) {
    var uri = webUri(value);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final dmdbs = host == 'www.dmdbs.net' && uri.path.startsWith('/kizuna/');
    // This board publishes its reader, DAT and form action over HTTP.
    if (dmdbs && uri.scheme == 'https' && !uri.hasPort) {
      uri = uri.replace(scheme: 'http');
    }
    final type = dmdbs
        ? BoardType.dmdbs
        : host == 'bbs.jpnkn.com'
        ? BoardType.jpnkn
        : host == 'komokomo.ddns.net'
        ? BoardType.komokomo
        : ['jbbs.shitaraba.net', 'jbbs.livedoor.jp'].contains(host)
        ? BoardType.shitaraba
        : BoardType.other;
    final thread = switch (type) {
      BoardType.jpnkn || BoardType.komokomo => RegExp(
        r'^/test/read\.cgi/[^/]+/\d+(?:/|$)',
      ).hasMatch(uri.path),
      BoardType.shitaraba => RegExp(
        r'^/bbs/read\.cgi/[^/]+/\d+/\d+(?:/|$)',
      ).hasMatch(uri.path),
      BoardType.dmdbs => RegExp(
        r'^/kizuna/test/read\.cgi/[^/]+/\d+(?:/|$)',
      ).hasMatch(uri.path),
      BoardType.other => false,
    };
    return BoardTarget(uri, type, thread);
  }
}
