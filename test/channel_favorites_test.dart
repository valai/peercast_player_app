import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:peercast_app/main.dart';
import 'package:peercast_app/models/channel.dart';
import 'package:peercast_app/services/app_settings.dart';
import 'package:peercast_app/services/channel_directory.dart';

Channel channel(String id, int listeners) => Channel(
  id: id,
  name: id,
  sourceId: 'test',
  sourceName: 'Test',
  tracker: '',
  contact: '',
  genre: '',
  description: '',
  comment: '',
  format: 'FLV',
  bitrate: 100,
  listeners: listeners,
);

class TestDirectory extends ChannelDirectory {
  final entries = [
    channel('popular', 100),
    channel('saved', 1),
    channel('new', 20),
  ];
  @override
  Future<DirectoryResult> refresh(List<YellowPage> sources) async =>
      DirectoryResult(entries, {});
}

void main() {
  testWidgets('favorites move above other channels only on refresh', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.favorites.add('test:saved');
    final directory = TestDirectory();
    settings.history = [directory.entries.first, directory.entries[1]];
    await tester.pumpWidget(MyApp(settings: settings, directory: directory));
    await tester.pumpAndSettle();

    List<String> order() => tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title! as Text).data!)
        .toList();
    expect(order(), ['saved', 'popular', 'new']);
    final newRow = find.ancestor(
      of: find.text('new'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: newRow, matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();
    expect(settings.favorites, contains('test:new'));
    expect(order(), ['saved', 'popular', 'new']);
    expect(
      find.descendant(of: newRow, matching: find.byIcon(Icons.star)),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('更新'));
    await tester.pumpAndSettle();
    expect(order(), ['new', 'saved', 'popular']);

    await tester.tap(find.text('閲覧履歴'));
    await tester.pumpAndSettle();
    expect(order(), ['popular', 'saved']);
    await tester.pumpWidget(const SizedBox());
  });
}
