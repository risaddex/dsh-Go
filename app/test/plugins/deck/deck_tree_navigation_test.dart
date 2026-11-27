import 'package:dsh_app/ui/plugins/deck/deck_tree_filter.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'deck_panel_test.dart' show FakeDeckReader, deckTree, openTab, ticket;

void main() {
  test('combines query and ticket status without inferring missing blockers', () {
    final tree = deckTree(
      standaloneIssues: [
        ticket(
          'ENG-10',
          'Ready standalone',
          blockedBy: const [DeckBlocker(key: '81', state: 'CLOSED')],
        ),
        ticket('ENG-11', 'Unknown blocker state', blockedBy: const [DeckBlocker(key: '81')]),
        ticket(
          'ENG-12',
          'Closed standalone',
          state: 'CLOSED',
          blockedBy: const [DeckBlocker(key: '81', state: 'OPEN')],
        ),
      ],
    );
    List<String> keys(DeckTreeStatus status, {String query = ''}) {
      final rows = filterDeckTree(tree, query: query, status: status, order: DeckTreeOrder.host);
      return [
        for (final group in rows.groups)
          for (final row in group.tickets) row.key,
        for (final row in rows.standalone!) row.key,
      ];
    }

    expect(keys(DeckTreeStatus.open), ['83', '84', '85', 'ENG-10', 'ENG-11']);
    expect(keys(DeckTreeStatus.closed), ['71', 'ENG-12']);
    expect(keys(DeckTreeStatus.blocked), ['84', 'ENG-11']);
    expect(keys(DeckTreeStatus.ready), ['83', 'ENG-10']);
    expect(keys(DeckTreeStatus.open, query: '  eng-10  '), ['ENG-10']);
    expect(keys(DeckTreeStatus.closed, query: '  eng-10  '), isEmpty);
    expect(keys(DeckTreeStatus.all, query: '#84'), ['84']);
    expect(keys(DeckTreeStatus.all, query: ' THE panel '), ['84']);
    final containerMatch = filterDeckTree(tree, query: '#56', status: DeckTreeStatus.all, order: DeckTreeOrder.host);
    expect(containerMatch.groups.single.container.key, '56');
    expect(containerMatch.groups.single.tickets, isEmpty);
    expect(containerMatch.standalone, isEmpty);
    expect(
      filterDeckTree(deckTree(), query: '', status: DeckTreeStatus.open, order: DeckTreeOrder.host).standalone,
      isNull,
    );
  });

  test('orders the containers and each group without changing host order', () {
    final tree = deckTree(standaloneIssues: [ticket('10', 'Alpha'), ticket('2', 'Zeta'), ticket('ENG-1', 'alpha')]);
    final byTitle = filterDeckTree(tree, query: '', status: DeckTreeStatus.all, order: DeckTreeOrder.title);
    expect(byTitle.groups.map((group) => group.container.key), ['70', '56']);
    expect(byTitle.groups.first.tickets.map((row) => row.key), ['71', '83', '84', '85']);
    expect(byTitle.standalone!.map((row) => row.key), ['10', 'ENG-1', '2']);

    final byKey = filterDeckTree(tree, query: '', status: DeckTreeStatus.all, order: DeckTreeOrder.key);
    expect(byKey.groups.map((group) => group.container.key), ['56', '70']);
    expect(byKey.groups.last.tickets.map((row) => row.key), ['71', '83', '84', '85']);
    expect(byKey.standalone!.map((row) => row.key), ['2', '10', 'ENG-1']);
    expect(tree.containers.first.tickets.map((row) => row.key), ['83', '84', '85', '71']);
    expect(tree.standaloneIssues!.map((row) => row.key), ['10', '2', 'ENG-1']);
  });

  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('filters loaded groups in place, retains truncation, and restores search on Back', (tester) async {
    usePhoneView(tester);
    final reader = FakeDeckReader()
      ..treeResult = deckTree(truncated: true, standaloneIssues: [ticket('ENG-1', 'Standalone')]);
    await openTab(tester, reader);
    final search = find.byType(TextField);
    expect(find.textContaining('仅适用于已加载的条目'), findsOneWidget);

    await tester.tap(find.byTooltip('按状态筛选票'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<DeckTreeStatus>, '受阻'));
    await tester.pumpAndSettle();
    expect(find.text('#70 Deck over remote'), findsOneWidget);
    expect(find.text('#84 Show the panel'), findsOneWidget);
    expect(find.text('#83 Forward the reads'), findsNothing);
    expect(find.text('ENG-1 Standalone'), findsNothing);

    await tester.enterText(search, 'eng-1');
    await tester.pump();
    expect(find.text('已加载的条目中没有匹配项'), findsOneWidget);
    expect(find.textContaining('这不是完整的树'), findsOneWidget);
    await tester.enterText(search, '#84');
    await tester.pump();
    await tester.tap(find.text('#84 Show the panel'));
    await pumpFrames(tester);
    expect(reader.ticketCalls, [('s1', '84')]);
    await tester.tap(find.text('返回'));
    await pumpFrames(tester);
    expect(tester.widget<TextField>(search).controller!.text, '#84');
    expect(find.text('状态：受阻'), findsOneWidget);
    expect(reader.treeCalls, ['s1']);
  });

  testWidgets('sort changes loaded row order without reading the deck again', (tester) async {
    usePhoneView(tester);
    final reader = FakeDeckReader()
      ..treeResult = deckTree(containers: const [], standaloneIssues: [ticket('10', 'Alpha'), ticket('2', 'Zeta')]);
    await openTab(tester, reader);
    final alpha = find.text('#10 Alpha');
    final zeta = find.text('#2 Zeta');
    expect(tester.getTopLeft(alpha).dy, lessThan(tester.getTopLeft(zeta).dy));
    await tester.tap(find.byTooltip('为已加载的条目排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<DeckTreeOrder>, '编号'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(zeta).dy, lessThan(tester.getTopLeft(alpha).dy));
    expect(reader.treeCalls, ['s1']);
    expect(reader.ticketCalls, isEmpty);
  });
}
