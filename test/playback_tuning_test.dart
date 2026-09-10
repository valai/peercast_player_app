import 'package:flutter_test/flutter_test.dart';
import 'package:peercast_app/services/playback_tuning.dart';

void main() {
  test('実機は音声を有効にしたまま音声基準と出力バッファを設定する', () async {
    final properties = <String, String>{};
    await configureNativePlayback((name, value) async {
      properties[name] = value;
    }, silentSimulator: false);
    expect(properties, {
      'cache-on-disk': 'no',
      'video-sync': 'audio',
      'audio-buffer': '0.5',
    });
  });

  test('音声非対応シミュレーターだけnull出力を使う', () async {
    final properties = <String, String>{};
    await configureNativePlayback((name, value) async {
      properties[name] = value;
    }, silentSimulator: true);
    expect(properties['ao'], 'null');
  });

  test('すべての非同期設定の完了を待ち、設定失敗は呼び出し元に返す', () async {
    final completed = <String>[];
    await configureNativePlayback((name, value) async {
      await Future<void>.delayed(Duration.zero);
      completed.add(name);
    }, silentSimulator: false);
    expect(completed, ['cache-on-disk', 'video-sync', 'audio-buffer']);

    await expectLater(
      configureNativePlayback((name, value) async {
        throw StateError('設定失敗');
      }, silentSimulator: false),
      throwsStateError,
    );
  });
}
