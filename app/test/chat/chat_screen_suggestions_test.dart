import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_screen_test.dart' show pumpScreen;
import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  setUpAll(() => chatClock = () => DateTime(2026, 10, 23, 9));

  group('conversation', () {
    for (final action in ['pick', 'dismiss', 'generic']) {
      testWidgets('suggestion card: $action', (tester) async {
        ChatState snapshot({String id = 'suggestions'}) => ChatState(
          items: [
            user(1, 'Show options'),
            tool(
              id,
              'suggest_next_steps',
              {},
              meta: {
                if (action != 'generic') 'dsh-go/card': 'deck.suggestions.v1',
                'dsh-go/view': {
                  'type': 'list',
                  'items': [
                    {'title': 'First option', 'insert': 'First prompt'},
                    {'title': 'Second option', 'insert': 'Second prompt'},
                  ],
                },
              },
            ),
          ],
          loading: false,
        );
        final harness = ChatHarness(session: 's1', states: {'s1': snapshot()});
        await pumpScreen(tester, harness);
        final input = find.byType(EditableText);
        final first = find.text('First option');
        final second = find.text('Second option');
        final dismiss = find.text('关闭建议');
        final chat = harness.controllers['s1']!;
        TextEditingController draft() => tester.widget<EditableText>(input).controller;
        await tester.enterText(input, 'existing draft');
        await pumpFrames(tester);
        if (action == 'generic') {
          expect(dismiss, findsNothing);
          await tester.tap(first);
          await tester.tap(second);
          await pumpFrames(tester);
          expect(draft().text, 'existing draft First prompt Second prompt ');
          expect(first, findsOneWidget);
        } else {
          expect(dismiss, findsOneWidget);
          await tester.tap(action == 'pick' ? first : dismiss);
          // Before Flutter can remove the card, a second tap must still lose.
          await tester.tap(second);
          await pumpFrames(tester);
          expect(draft().text, action == 'pick' ? 'First prompt' : 'existing draft');
          expect(first, findsNothing);
          expect(second, findsNothing);
          expect(dismiss, findsNothing);

          chat.emit(snapshot());
          await pumpFrames(tester);
          expect(first, findsNothing, reason: 'a new transcript snapshot must not rearm the same call');
          chat.emit(snapshot(id: 'different-card'));
          await pumpFrames(tester);
          expect(first, findsOneWidget, reason: 'a distinct call may offer fresh suggestions');
        }
        expect(chat.sent, isEmpty);
      });
    }
  });
}
