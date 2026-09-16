import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/services/peercast_engine.dart';

void main() {
  test('external Mbps is distinct from cumulative bytes and accepts native numbers', () {
    final snapshot = EngineSnapshot.fromJson({
      'bytesOut': 5242880000,
      'outboundMbps': 1.25,
    });
    expect(snapshot.bytesOut, 5242880000);
    expect(snapshot.outboundMbps, 1.25);
    expect(EngineSnapshot.fromJson({'outboundMbps': 1}).outboundMbps, 1.0);
    expect(EngineSnapshot.fromJson({}).outboundMbps, 0);
  });
}
