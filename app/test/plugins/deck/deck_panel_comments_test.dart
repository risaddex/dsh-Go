import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/plugins/deck/deck_panel_comments_state.dart';
import 'package:dsh_app/ui/plugins/deck/deck_panel_comments.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness(DeckCommentsReader? reader, {String ticketKey = 'ABC-7'}) => ProviderScope(
    overrides: [deckPanelCommentsReaderProvider.overrideWithValue(reader)],
    child: MaterialApp(
      theme: buildLightTheme(),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: DeckPanelComments(sessionId: 's1', ticketKey: ticketKey),
      ),
    ),
  );

  testWidgets('without comments capability there is no comments UI', (tester) async {
    await tester.pumpWidget(harness(null));
    await tester.pumpAndSettle();
    expect(find.text('Comments'), findsNothing);
    expect(find.text('Load comments'), findsNothing);
  });

  testWidgets('loads on tap, retries the same cursor, keeps previous comments', (tester) async {
    final calls = <(String, String, String?)>[];
    await tester.pumpWidget(
      harness((session, key, {cursor}) async {
        calls.add((session, key, cursor));
        if (calls.length == 2) throw StateError('temporary failure');
        return cursor == null
            ? const DeckCommentsPage(
                comments: [DeckComment(body: 'First')],
                nextCursor: 'opaque',
              )
            : const DeckCommentsPage(
                comments: [DeckComment(body: 'Second', author: 'Maintainer')],
                truncated: true,
              );
      }),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.text('Load comments'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    await tester.tap(find.text('Load more comments'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Couldn’t load comments'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('Maintainer'), findsOneWidget);
    expect(find.text('Some comment content or history could not be shown.'), findsOneWidget);
    expect(find.text('Load more comments'), findsNothing);
    expect(calls, [('s1', 'ABC-7', null), ('s1', 'ABC-7', 'opaque'), ('s1', 'ABC-7', 'opaque')]);
  });

  testWidgets('a late reply from a different ticket does not leak into the new one', (tester) async {
    final pending = Completer<DeckCommentsPage>();
    Future<DeckCommentsPage> reader(String _, String key, {String? cursor}) =>
        key == 'ABC-7' ? pending.future : Future.value(const DeckCommentsPage(comments: []));
    await tester.pumpWidget(harness(reader));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load comments'));
    await tester.pump();
    await tester.pumpWidget(harness(reader, ticketKey: 'ABC-8'));
    pending.complete(const DeckCommentsPage(comments: [DeckComment(body: 'Other ticket')]));
    await tester.pumpAndSettle();
    expect(find.text('Other ticket'), findsNothing);
    await tester.tap(find.text('Load comments'));
    await tester.pumpAndSettle();
    expect(find.text('No comments'), findsOneWidget);
  });
}
