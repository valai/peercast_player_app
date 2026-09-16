import 'dart:convert';
import 'dart:isolate';

import 'package:charset_converter/charset_converter.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:http/http.dart' as http;

import 'board_resolver.dart';

final _unescape = HtmlUnescape();
final _breakTag = RegExp(r'<br\s*/?>', caseSensitive: false);
final _htmlTag = RegExp(r'<[^>]*>');

String boardText(String value) => _unescape
    .convert(value.replaceAll(_breakTag, '\n').replaceAll(_htmlTag, ''))
    .trim();

class BoardPost {
  const BoardPost(
    this.number,
    this.name,
    this.date,
    this.body, {
    this.mail = '',
  });
  final int number;
  final String name, date, body, mail;
}

class BoardThread {
  const BoardThread(this.title, this.posts);
  final String title;
  final List<BoardPost> posts;
}

class BoardThreadEntry {
  const BoardThreadEntry(this.target, this.title, this.count);
  final BoardTarget target;
  final String title;
  final int count;
}

class BoardClient {
  BoardClient({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  // Bound the cache to the most recently viewed thread.
  (Uri, String, BoardThread)? _cached;
  String charset(BoardTarget target) =>
      target.type == BoardType.shitaraba ? 'EUC-JP' : 'Shift_JIS';
  List<String> parts(BoardTarget target) {
    if (!target.isThread || target.type == BoardType.other) {
      throw const FormatException('対応するスレッドURLではありません');
    }
    return target.threadParts;
  }

  Future<String> decode(http.Response response, BoardTarget target) {
    final encoding =
        RegExp(r'charset=([^;\s]+)', caseSensitive: false)
            .firstMatch(response.headers['content-type'] ?? '')
            ?.group(1)
            ?.replaceAll('"', '') ??
        charset(target);
    if (encoding.toLowerCase() == 'utf-8') {
      return Future.value(utf8.decode(response.bodyBytes));
    }
    // Japanese BBS DAT uses Windows extensions even when labeled Shift_JIS.
    final normalized = encoding.toLowerCase().replaceAll('-', '_');
    return CharsetConverter.decode(
      ['shift_jis', 'sjis', 'windows_31j'].contains(normalized)
          ? 'cp932'
          : encoding,
      response.bodyBytes,
    );
  }

  static BoardThread parse(String text, BoardType type) {
    final posts = <BoardPost>[];
    var title = '';
    var lineNumber = 0;
    for (final line in const LineSplitter().convert(text)) {
      lineNumber++;
      if (line.trim().isEmpty) continue;
      final f = line.split('<>');
      final shitaraba = type == BoardType.shitaraba;
      final offset = shitaraba ? 1 : 0;
      if (f.length < 5 + offset) throw const FormatException('スレッドの応答形式が不正です');
      final number = shitaraba ? int.tryParse(f[0]) : lineNumber;
      if (number == null) throw const FormatException('レス番号が不正です');
      if (title.isEmpty) title = boardText(f[4 + offset]);
      posts.add(
        BoardPost(
          number,
          boardText(f[offset]),
          boardText(f[2 + offset]),
          boardText(f[3 + offset]),
          mail: boardText(f[1 + offset]),
        ),
      );
    }
    if (posts.isEmpty) throw const FormatException('レスを取得できませんでした');
    return BoardThread(title, posts);
  }

  static List<BoardThreadEntry> parseSubjects(String text, BoardTarget target) {
    final entries = <BoardThreadEntry>[];
    for (final line in const LineSplitter().convert(text)) {
      final match = RegExp(r'^(\d+)\.(?:dat|cgi)(?:<>|,)(.*)\s*\((\d+)\)\s*$')
          .firstMatch(line);
      if (match == null) continue;
      entries.add(
        BoardThreadEntry(
          target.threadTarget(match[1]!),
          boardText(match[2]!),
          int.parse(match[3]!),
        ),
      );
    }
    return entries;
  }

  Future<List<BoardThreadEntry>> fetchThreads(BoardTarget target) async {
    final home = target.boardUri;
    final path = '${home.path.replaceFirst(RegExp(r'/+$'), '')}/subject.txt';
    final response = await client
        .get(target.endpoint(path))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final text = await decode(response, target);
    final entries = parseSubjects(text, target);
    if (entries.isEmpty && text.trim().isNotEmpty) {
      throw const FormatException('スレッド一覧の応答形式が不正です');
    }
    return entries;
  }

  Future<BoardTarget?> nextThread(
    BoardTarget current,
    BoardThread thread,
  ) async {
    final entries = await fetchThreads(current);
    final candidates = entries
        .where(
          (e) =>
              e.count < 1000 &&
              int.parse(e.target.threadKey) > int.parse(current.threadKey),
        )
        .toList();
    for (final post in thread.posts.reversed.take(100)) {
      for (final match in RegExp(
        r'https?://[^\s<>"「」]+',
      ).allMatches(post.body)) {
        final linked = BoardResolver.resolve(match[0]!);
        if (linked == null || !linked.isThread) continue;
        for (final entry in candidates) {
          if (linked.boardUri == current.boardUri &&
              linked.threadKey == entry.target.threadKey) {
            return entry.target;
          }
        }
      }
    }
    String series(String title) => title
        .toLowerCase()
        .replaceAll(RegExp(r'[０-９]'), '#')
        .replaceAll(
          RegExp(r'[0-9]+|part|その|スレッド|スレ|[\s#＃()（）【】\[\]・._ー-]'),
          '',
        );
    final name = series(thread.title);
    final matching =
        candidates
            .where((e) => name.isNotEmpty && series(e.title) == name)
            .toList()
          ..sort(
            (a, b) =>
                int.parse(a.target.threadKey)
                    .compareTo(int.parse(b.target.threadKey)),
          );
    return matching.isEmpty ? null : matching.first.target;
  }

  Future<BoardThread> fetch(BoardTarget target) async {
    final p = parts(target);
    final path = target.type == BoardType.shitaraba
        ? '/bbs/rawmode.cgi/${p[2]}/${p[3]}/${p[4]}/'
        : '/${p[2]}/dat/${p[3]}.dat';
    final response = await client
        .get(target.endpoint(target.pathPrefix + path))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final text = await decode(response, target);
    final cached = _cached;
    if (cached != null && cached.$1 == target.uri && cached.$2 == text) {
      return cached.$3;
    }
    final type = target.type;
    // Parsing every response and HTML entity must not block video or input.
    final thread = await Isolate.run(() => parse(text, type));
    _cached = (target.uri, text, thread);
    return thread;
  }

  Future<void> post(
    BoardTarget target,
    String name,
    String mail,
    String message,
  ) async {
    if (message.trim().isEmpty) throw const FormatException('本文を入力してください');
    final p = parts(target);
    final shitaraba = target.type == BoardType.shitaraba;
    final fields = shitaraba
        ? {
            'DIR': p[2],
            'BBS': p[3],
            'KEY': p[4],
            'NAME': name,
            'MAIL': mail,
            'MESSAGE': message,
            'TIME': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
            'submit': '書き込む',
          }
        : {
            'bbs': p[2],
            'key': p[3],
            'FROM': name,
            'mail': mail,
            'MESSAGE': message,
            'time': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
          };
    if (target.type == BoardType.dmdbs) {
      fields.addAll({'submit': '書き込む', 'url': '', 'password': ''});
    }
    Future<String> encode(String value) async {
      final bytes = await CharsetConverter.encode(charset(target), value);
      if (await CharsetConverter.decode(charset(target), bytes) != value) {
        throw const FormatException('掲示板の文字コードで送信できない文字が含まれています');
      }
      return bytes.map((b) => '%${b.toRadixString(16).padLeft(2, '0')}').join();
    }

    final body = <String>[];
    for (final entry in fields.entries) {
      body.add('${entry.key}=${await encode(entry.value)}');
    }
    final request =
        http.Request(
            'POST',
            target.endpoint(
              shitaraba
                  ? '/bbs/write.cgi/${p[2]}/${p[3]}/${p[4]}/'
                  : '${target.pathPrefix}/test/bbs.cgi',
            ),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': target.uri.toString(),
          })
          ..body = body.join('&');
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 20)),
    ).timeout(const Duration(seconds: 20));
    final result = await decode(response, target);
    final title =
        RegExp(
          r'<title[^>]*>([\s\S]*?)</title>',
          caseSensitive: false,
        ).firstMatch(result)?.group(1) ??
        '';
    if (response.statusCode != 200 ||
        !RegExp(r'書きこみました|書き込みました|書き込みが完了').hasMatch(boardText(title))) {
      throw Exception(
        '投稿の成功を確認できません。再送前に更新して確認してください。\n${boardText(result).substring(0, boardText(result).length.clamp(0, 300))}',
      );
    }
  }

  void dispose() => client.close();
}
