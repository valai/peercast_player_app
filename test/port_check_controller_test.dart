import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/services/peercast_engine.dart';
import 'package:peercast_app/services/port_check_controller.dart';

class Listener implements PortListenerBackend {
  bool running = false, ready = true;
  int? port;
  int stops = 0;
  @override
  Future<void> startListener(String directory, int port, int relays) async {
    this.port = port;
    running = true;
  }

  @override
  Future<EngineSnapshot> snapshot() async =>
      EngineSnapshot(running: running, listening: running && ready);
  @override
  Future<void> stop() async {
    running = false;
    stops++;
  }
}

void main() {
  for (final scenario in [
    'ready',
    'mobile',
    'wifiLost',
    'cancel',
    'listenerLost',
  ]) {
    testWidgets('確認用待受: $scenario', (tester) async {
      final engine = Listener()..ready = scenario != 'cancel';
      var links = [
        scenario == 'mobile'
            ? ConnectivityResult.mobile
            : ConnectivityResult.wifi,
      ];
      final network = StreamController<List<ConnectivityResult>>();
      final controller = PortCheckController(
        port: 17145,
        relays: 1,
        engine: engine,
        directory: () async => Directory('.'),
        checkConnectivity: () async => links,
        connectivityChanges: network.stream,
      );
      final pending = controller.start();
      await tester.pump();
      if (scenario == 'mobile') {
        expect(engine.port, isNull);
        expect(controller.listening, false);
      } else if (scenario == 'cancel') {
        expect(controller.starting, true);
        expect(controller.listening, false);
        await controller.stop();
        engine.ready = true;
        await tester.pump(const Duration(seconds: 1));
        expect(controller.listening, false);
        expect(engine.running, false);
      } else {
        expect(engine.port, 17145);
        expect(controller.listening, true);
        if (scenario == 'wifiLost') {
          links = [ConnectivityResult.mobile];
          network.add(links);
          await tester.pump();
          expect(engine.running, false);
        } else if (scenario == 'listenerLost') {
          engine.running = false;
          await tester.pump(const Duration(seconds: 1));
          expect(controller.listening, false);
        } else {
          await controller.stop();
          expect(engine.running, false);
          final restarting = controller.start();
          await tester.pump();
          await restarting;
          expect(controller.listening, true);
        }
      }
      await pending;
      controller.dispose();
      await tester.pump();
      expect(engine.running, false);
      unawaited(network.close());
      await tester.pump();
    });
  }
}
