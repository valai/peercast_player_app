import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../models/channel.dart';

class EngineSnapshot {
  const EngineSnapshot({
    this.running = false,
    this.listening = false,
    this.playing = false,
    this.relays = 0,
    this.bytesOut = 0,
    this.firewall = 'unknown',
    this.status = 'stopped',
    this.portCheckError = '',
  });
  factory EngineSnapshot.fromJson(Map<String, dynamic> j) => EngineSnapshot(
    running: j['running'] == true,
    listening: j['listening'] == true,
    playing: j['playing'] == true,
    relays: (j['relays'] as num?)?.toInt() ?? 0,
    bytesOut: (j['bytesOut'] as num?)?.toInt() ?? 0,
    firewall: j['firewall'] as String? ?? 'unknown',
    status: j['status'] as String? ?? 'stopped',
    portCheckError: j['portCheckError'] as String? ?? '',
  );
  final bool running, playing, listening;
  final int relays, bytesOut;
  final String firewall, status, portCheckError;
}

abstract interface class EngineBackend {
  Future<Uri> start(Channel channel, String directory, int port, int relays);
  Future<EngineSnapshot> snapshot();
  Future<void> connect(Channel channel);
  Future<void> checkPort(Channel channel);
  Future<void> stop();
}

abstract interface class PortListenerBackend {
  Future<void> startListener(String directory, int port, int relays);
  Future<EngineSnapshot> snapshot();
  Future<void> stop();
}

// Each screen has an owner token. Late disposal of an old screen cannot stop
// the new screen's core. Blocking FFI calls run only in the worker isolate.
class PeerCastEngine implements EngineBackend, PortListenerBackend {
  final String owner =
      '${DateTime.now().microsecondsSinceEpoch}-${_nextOwner++}';
  static int _nextOwner = 0;
  static Future<SendPort>? _worker;
  static Future<SendPort> _spawn() async {
    final ready = ReceivePort();
    await Isolate.spawn(_engineWorker, ready.sendPort);
    final result = await ready.first;
    ready.close();
    if (result is String) throw StateError(result);
    return result as SendPort;
  }

  Future<dynamic> _call(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    final worker = await (_worker ??= _spawn());
    final reply = ReceivePort();
    worker.send({'op': op, 'owner': owner, 'reply': reply.sendPort, ...args});
    final result = await reply.first as Map;
    reply.close();
    if (result['error'] != null) throw StateError(result['error'] as String);
    return result['value'];
  }

  @override
  Future<Uri> start(
    Channel channel,
    String directory,
    int port,
    int relays,
  ) async {
    if (!channel.playable) throw StateError('FLV形式のチャンネルを選択してください');
    await startListener(directory, port, relays);
    return Uri.parse(
      'http://127.0.0.1:$port/stream/${channel.id.toUpperCase()}.flv',
    );
  }

  @override
  Future<void> startListener(String directory, int port, int relays) async {
    await _call('start', {
      'directory': directory,
      'port': port,
      'relays': relays,
    });
  }

  @override
  Future<EngineSnapshot> snapshot() async => EngineSnapshot.fromJson(
    Map<String, dynamic>.from(await _call('snapshot') as Map),
  );
  @override
  Future<void> connect(Channel channel) async {
    await _call('connect', {'id': channel.id, 'tracker': channel.tracker});
  }

  @override
  Future<void> checkPort(Channel channel) async {
    await _call('checkPort', {'tracker': channel.tracker, 'id': channel.id});
  }

  @override
  Future<void> stop() async {
    if (_worker != null) await _call('stop');
  }
}

void _engineWorker(SendPort ready) {
  try {
    final library = Platform.isIOS
        ? DynamicLibrary.open(
            '${File(Platform.resolvedExecutable).parent.path}/Frameworks/peercast_mobile.framework/peercast_mobile',
          )
        : DynamicLibrary.open('libpeercast_mobile.so');
    final start = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Int32),
          int Function(Pointer<Utf8>, int, int)
        >('pc_start');
    final connect = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('pc_connect');
    final stop = library.lookupFunction<Int32 Function(), int Function()>(
      'pc_stop',
    );
    final checkPort = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('pc_check_port');
    final error = library
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'pc_error',
        );
    final snapshot = library
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'pc_snapshot',
        );
    void check(int code) {
      if (code != 0) throw StateError(error().toDartString());
    }

    String? owner;
    final commands = ReceivePort();
    ready.send(commands.sendPort);
    commands.listen((dynamic message) {
      final m = message as Map;
      final reply = m['reply'] as SendPort;
      try {
        dynamic value;
        if (m['op'] == 'start') {
          final path = (m['directory'] as String).toNativeUtf8();
          try {
            check(start(path, m['port'] as int, m['relays'] as int));
            owner = m['owner'] as String;
          } catch (_) {
            stop();
            rethrow;
          } finally {
            calloc.free(path);
          }
        } else if (owner == m['owner']) {
          switch (m['op']) {
            case 'stop':
              check(stop());
              owner = null;
            case 'connect':
              final id = (m['id'] as String).toNativeUtf8();
              final tracker = (m['tracker'] as String).toNativeUtf8();
              try {
                check(connect(id, tracker));
              } finally {
                calloc.free(id);
                calloc.free(tracker);
              }
            case 'checkPort':
              final id = (m['id'] as String).toNativeUtf8();
              final tracker = (m['tracker'] as String).toNativeUtf8();
              try {
                check(checkPort(tracker, id));
              } finally {
                calloc.free(id);
                calloc.free(tracker);
              }
            case 'snapshot':
              value = jsonDecode(snapshot().toDartString());
          }
        } else if (m['op'] == 'snapshot') {
          value = {'running': false, 'status': 'replaced'};
        }
        reply.send({'value': value});
      } catch (e) {
        reply.send({'error': '$e'});
      }
    });
  } catch (e) {
    ready.send('視聴エンジンを読み込めませんでした: $e');
  }
}
