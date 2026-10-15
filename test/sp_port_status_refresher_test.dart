import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:peercast_app/services/peercast_engine.dart';
import 'package:peercast_app/services/sp_port_status_refresher.dart';

class Listener implements PortListenerBackend {
  bool running = false;
  int starts = 0, stops = 0;

  @override
  Future<void> startListener(String directory, int port, int relays) async {
    expect(port, 17145);
    expect(relays, 2);
    starts++;
    running = true;
  }

  @override
  Future<EngineSnapshot> snapshot() async =>
      EngineSnapshot(running: running, listening: running);

  @override
  Future<void> stop() async {
    running = false;
    stops++;
  }
}

void main() {
  test('SPの状態ページ取得中だけ待受を起動し、完了後に停止する', () async {
    final engine = Listener();
    var sawListener = false;
    final refresher = SpPortStatusRefresher(
      engine: engine,
      checkConnectivity: () async => [ConnectivityResult.wifi],
      directory: () async => Directory('.'),
      clientFactory: () => MockClient((request) async {
        expect(request.url, Uri.parse('http://bayonet.ddo.jp/sp/'));
        expect(request.headers['Cache-Control'], 'no-cache');
        sawListener = engine.running;
        return http.Response('', 200);
      }),
    );

    expect(await refresher.refresh(port: 17145, relays: 2), isTrue);
    expect(sawListener, isTrue);
    expect(engine.starts, 1);
    expect(engine.stops, 1);
    expect(engine.running, isFalse);
    refresher.dispose();
  });

  test('Wi-Fi以外では待受を開始しない', () async {
    final engine = Listener();
    final refresher = SpPortStatusRefresher(
      engine: engine,
      checkConnectivity: () async => [ConnectivityResult.mobile],
      directory: () async => Directory('.'),
      clientFactory: () => MockClient((_) async => http.Response('', 200)),
    );

    expect(await refresher.refresh(port: 17145, relays: 2), isFalse);
    expect(engine.starts, 0);
    expect(engine.stops, 0);
    refresher.dispose();
  });
}
