import '../models/channel.dart';
import 'channel_directory.dart';

/// PRスクリーンショット用。実際のYPへの問い合わせは行わない。
class ScreenshotChannelDirectory extends ChannelDirectory {
  @override
  Future<DirectoryResult> refresh(List<YellowPage> sources) async {
    final now = DateTime.now();
    const samples = [
      ('そらいろゲーム部', 'ゲーム', 'のんびり冒険のつづき', '初見プレイで探索中', 128, 2500),
      ('こもれびラジオ', '雑談', '午後のまったりトーク', '作業のおともにどうぞ', 86, 128),
      ('ピクセル工房', '創作', 'ドット絵で小さな街づくり', '今日はお店を描きます', 64, 1800),
      ('週末レトロ倶楽部', 'ゲーム', '懐かしのアクションに挑戦', 'クリアを目指して練習中', 42, 2000),
      ('月あかり書斎', '作業', '読書とノート整理', 'ゆっくり過ごす夜', 31, 1200),
      ('コードとコーヒー', 'プログラミング', '小さなアプリを制作中', '画面のデザインを調整', 23, 1600),
      ('旅するスケッチ', 'お絵かき', '想像の風景を描く', '水彩風の色塗り', 12, 2200),
      ('星空ステーション', '雑談', '今日のできごと', '気ままにおしゃべり', -1, 1500),
    ];
    return DirectoryResult([
      for (var i = 0; i < samples.length; i++)
        Channel(
          id: (i + 1).toRadixString(16).padLeft(32, '0'),
          name: samples[i].$1,
          sourceId: 'screenshot-${i % 2}',
          sourceName: 'SP',
          tracker: '',
          contact: '',
          genre: samples[i].$2,
          description: samples[i].$3,
          comment: samples[i].$4,
          format: 'FLV',
          bitrate: samples[i].$6,
          listeners: samples[i].$5,
          broadcastStartedAt: now.subtract(
            Duration(minutes: 135 - i * 13, seconds: 24 + i * 3),
          ),
        ),
    ], {});
  }
}
