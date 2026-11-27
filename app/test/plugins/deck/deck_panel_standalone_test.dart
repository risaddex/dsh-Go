import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'deck_panel_test.dart' show FakeDeckReader, deckTree, openTab, ticket;

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('panel in 对话详情 › 插件', () {
    testWidgets('an explicitly empty standalone list is not reported as missing support', (tester) async {
      usePhoneView(tester);
      await openTab(tester, FakeDeckReader()..treeResult = deckTree(containers: [], standaloneIssues: []));
      expect(find.text('这个工作区没有打开的地图、规格或独立票'), findsOneWidget);
      expect(find.text('此主机不在这里列出独立票。'), findsNothing);
    });

    testWidgets('standalone-only workspace opens an issue without inventing a container', (tester) async {
      usePhoneView(tester);
      final reader = FakeDeckReader()
        ..treeResult = deckTree(containers: [], standaloneIssues: [ticket('84', 'Show the panel')]);
      await openTab(tester, reader);
      expect(find.text('独立票'), findsOneWidget);
      expect(find.text('此主机不在这里列出独立票。'), findsNothing);
      await tester.tap(find.text('#84 Show the panel'));
      await pumpFrames(tester);
      expect(reader.ticketCalls, [('s1', '84')]);
      expect(find.text('Render the tree and the ticket.'), findsOneWidget);
    });
  });
}
