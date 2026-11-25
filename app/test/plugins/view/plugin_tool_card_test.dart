// Tool cards: a plugin tool's `presentationMeta` returns
// {"dsh-go/view": View}; DSH stores it as `tool/result.data.meta`; the app
// draws it in the tool row (docs/design/native-plugins-views.md §8).

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart' show DshUiList, DshUiListItem;
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/stream_row.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../native/support.dart' show FakeComposer, withComposer;
import 'fixtures.dart';
import 'support.dart';

Future<void> _noRespond(ApprovalRequest _, ApprovalDecision _) async {}

const _args = {'city': '东京', 'days': 3};

ToolChatItem weather(String id, {Object? meta, ToolStatus status = ToolStatus.succeeded}) =>
    tool(id, 'weather_forecast', _args, status: status, result: '{"city":"东京","high":21}', meta: meta);

Future<void> pumpRows(
  WidgetTester tester,
  List<ToolChatItem> items, {
  ToolCardPlacement card = ToolCardPlacement.inline,
}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in items)
                ToolRow(key: ValueKey(item.callId), item: item, card: card, onRespond: _noRespond),
            ],
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

Future<void> expand(WidgetTester tester, String id) async {
  final header = find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(Row)).first;
  await tester.ensureVisible(header);
  await tester.pump();
  await tester.tap(header);
  await pumpFrames(tester, 12);
}

Finder inRow(String id, Finder f) => find.descendant(of: find.byKey(ValueKey(id)), matching: f);

/// The events DSH writes for one plugin tool call.
List<SessionLogEvent> events(Object? meta) => [
  for (final (seq, type, data) in [
    (1, 'turn/start', {'turn': 1}),
    (2, 'step/start', {'turn': 1, 'step': 1}),
    (
      3,
      'tool/call',
      {'turn': 1, 'step': 1, 'callId': 'call-1', 'name': 'weather_forecast', 'arguments': jsonEncode(_args)},
    ),
    (
      4,
      'tool/result',
      {
        'turn': 1,
        'step': 1,
        'message': {
          'id': 'm1',
          'role': 'tool',
          'toolCallId': 'call-1',
          'content': [
            {'type': 'text', 'text': '{"city":"东京","high":21}'},
          ],
        },
        'meta': ?meta,
      },
    ),
    (5, 'step/end', {'turn': 1, 'step': 1}),
    (
      6,
      'turn/end',
      {
        'turn': 1,
        'reason': {'kind': 'completed'},
      },
    ),
  ])
    SessionLogEvent.fromJson({'seq': seq, 'time': 1792700000000 + seq, 'type': type, 'data': data}),
];

ToolChatItem replayed(Object? meta) {
  final transcript = ChatTranscript();
  // Round-trip through JSON: what a reload of the session log hands the app.
  for (final e in events(meta)) {
    transcript.apply(
      SessionLogEvent.fromJson(
        jsonDecode(jsonEncode({'seq': e.seq, 'time': e.time.millisecondsSinceEpoch, 'type': e.type, 'data': e.data})),
      ),
    );
  }
  return transcript.items.whereType<ToolChatItem>().single;
}

void main() {
  setUpAll(loadTestFonts);

  group('ToolView', () {
    test('reads meta["dsh-go/view"] on a successful call only', () {
      expect(ToolView.of(weather('a')).pluginView, isNull);
      expect(ToolView.of(weather('a', meta: {'diffs': []})).pluginView, isNull);
      final ok = ToolView.of(weather('a', meta: {'dsh-go/view': weatherCard}));
      expect(ok.pluginView, isA<DshUiParsed>());
      expect(ok.pluginTitle, '东京 · 未来 3 天');
      final failed = ToolView.of(weather('a', meta: {'dsh-go/view': weatherCard}, status: ToolStatus.failed));
      expect(failed.pluginView, isNull);
      expect(ToolView.of(weather('a', meta: {'dsh-go/view': 'garbage'})).pluginView, isA<DshUiInvalid>());
    });

    test('8 KiB: a bigger card is not drawn', () {
      final big = {
        'type': 'stack',
        'title': '大',
        'children': [
          {'type': 'text', 'text': '字' * 3000},
        ],
      };
      expect(ToolView.of(weather('a', meta: {'dsh-go/view': big})).pluginView, isA<DshUiInvalid>());
    });

    test('the session log carries the view through a reload', () {
      final item = replayed({'dsh-go/view': weatherCard});
      expect((item.meta as Map)['dsh-go/view'], weatherCard);
      expect(ToolView.of(item).pluginTitle, '东京 · 未来 3 天');
      expect(replayed(null).meta, isNull);
    });
  });

  group('ToolRow', () {
    testWidgets('no view: nothing changes', (tester) async {
      await pumpRows(tester, [weather('plain')]);
      expect(inRow('plain', find.text('东京')), findsOneWidget);
      await expand(tester, 'plain');
      expect(find.byType(PluginToolCard), findsNothing);
      expect(inRow('plain', find.byType(ToolDetail)), findsOneWidget);
    });

    testWidgets('a view: the card open by default, its title in the row when closed', (tester) async {
      await pumpRows(tester, [
        weather('card', meta: {'dsh-go/view': weatherCard}),
      ]);
      expect(inRow('card', find.byType(PluginToolCard)), findsOneWidget);
      expect(inRow('card', find.text('最高')), findsOneWidget);
      expect(inRow('card', find.text('21°')), findsOneWidget);
      // The title is on the card; the row says what was asked.
      expect(inRow('card', find.text('东京 · 未来 3 天')), findsOneWidget);
      expect(inRow('card', find.text('东京')), findsOneWidget);
      // Parameters and result wait under 「详情」.
      expect(inRow('card', find.byType(ToolDetail)), findsNothing);
      await tester.tap(inRow('card', find.text('详情')));
      await pumpFrames(tester, 12);
      expect(inRow('card', find.byType(ToolDetail)), findsOneWidget);
      // Closing the row folds the whole thing; the row takes the title.
      await expand(tester, 'card');
      expect(inRow('card', find.text('最高')), findsNothing);
      expect(inRow('card', find.text('东京 · 未来 3 天')), findsOneWidget);
      expect(inRow('card', find.text('东京')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the card opens when the result arrives, unless closed by hand', (tester) async {
      final running = weather('late', status: ToolStatus.running);
      final done = weather('late', meta: {'dsh-go/view': weatherCard});
      await pumpRows(tester, [running]);
      expect(inRow('late', find.text('最高')), findsNothing);
      await pumpRows(tester, [done]);
      await pumpFrames(tester, 12);
      expect(inRow('late', find.text('最高')), findsOneWidget);
      // Closed by hand: it stays closed while the row updates.
      await expand(tester, 'late');
      await pumpRows(tester, [
        weather('late', meta: {'dsh-go/view': weatherCard, 'n': 2}),
      ]);
      await pumpFrames(tester, 12);
      expect(inRow('late', find.text('最高')), findsNothing);
    });

    testWidgets('inside a folded turn: a plain row, the card is elsewhere', (tester) async {
      await pumpRows(tester, [
        weather('in', meta: {'dsh-go/view': weatherCard}),
      ], card: ToolCardPlacement.rowOnly);
      expect(inRow('in', find.text('东京 · 未来 3 天')), findsOneWidget);
      expect(inRow('in', find.text('最高')), findsNothing);
      await expand(tester, 'in');
      expect(inRow('in', find.byType(PluginToolCard)), findsNothing);
      expect(inRow('in', find.byType(ToolDetail)), findsOneWidget);
    });

    testWidgets('outside a folded turn: the card alone', (tester) async {
      await pumpRows(tester, [
        weather('out', meta: {'dsh-go/view': weatherCard}),
      ], card: ToolCardPlacement.cardOnly);
      expect(inRow('out', find.text('最高')), findsOneWidget);
      expect(inRow('out', find.text('东京 · 未来 3 天')), findsOneWidget);
      // No tool line, no 「详情」.
      expect(inRow('out', find.byType(StreamRowFrame)), findsNothing);
      expect(inRow('out', find.text('详情')), findsNothing);
      final row = tester.getRect(find.byKey(const ValueKey('out')));
      final card = tester.getRect(inRow('out', find.byType(PluginToolCard)));
      expect(card.top - row.top, 4);
      expect(row.bottom - card.bottom, 4);
    });

    testWidgets('no title: the usual summary stays', (tester) async {
      await pumpRows(tester, [
        weather(
          'untitled',
          meta: {
            'dsh-go/view': {'type': 'metric', 'label': '最高', 'value': '21°'},
          },
        ),
      ]);
      expect(inRow('untitled', find.text('东京')), findsOneWidget);
    });

    testWidgets('a broken view: one line, then the usual detail', (tester) async {
      await pumpRows(tester, [
        weather(
          'broken',
          meta: {
            'dsh-go/view': {'type': 'gauge'},
          },
        ),
      ]);
      expect(inRow('broken', find.text('东京')), findsOneWidget);
      await expand(tester, 'broken');
      expect(inRow('broken', find.text('插件界面有误')), findsOneWidget);
      expect(inRow('broken', find.byType(ToolDetail)), findsOneWidget);
    });

    testWidgets('bad data in one row leaves the others alone', (tester) async {
      final cyclic = <String, Object?>{'type': 'stack'};
      cyclic['children'] = [cyclic];
      await pumpRows(tester, [
        weather('a', meta: {'dsh-go/view': weatherCard}),
        weather('b', meta: {'dsh-go/view': cyclic}),
        weather('c', meta: {'dsh-go/view': double.nan}),
        weather(
          'd',
          meta: {
            'dsh-go/view': {'type': 'image', 'src': 'https://tracker.example/p.png'},
          },
        ),
        weather(
          'e',
          meta: {
            'dsh-go/view': {
              'type': 'stack',
              'children': [
                weatherCard,
                {'type': 'x'},
              ],
            },
          },
        ),
        weather('f'),
      ]);
      // a, d and e draw a card: open already. b, c and f open by hand.
      for (final id in ['b', 'c', 'f']) {
        await expand(tester, id);
      }
      expect(tester.takeException(), isNull);
      expect(inRow('a', find.text('21°')), findsOneWidget);
      expect(inRow('b', find.text('插件界面有误')), findsOneWidget);
      expect(inRow('c', find.text('插件界面有误')), findsOneWidget);
      expect(inRow('d', find.text('图片无法显示')), findsOneWidget);
      expect(inRow('e', find.text('这部分无法显示')), findsOneWidget);
      expect(inRow('f', find.byType(ToolDetail)), findsOneWidget);
    });

    testWidgets('tool cards are read-only in phase 0', (tester) async {
      await pumpRows(tester, [
        weather(
          'ro',
          meta: {
            'dsh-go/view': {
              'type': 'stack',
              'title': '只读',
              'children': [actionsView, choiceView, listView],
            },
          },
        ),
      ]);
      expect(inRow('ro', find.text('续费')), findsNothing);
      expect(inRow('ro', find.text('重置')), findsNothing);
      expect(inRow('ro', find.text('近 7 天')), findsOneWidget);
      final card = find.descendant(
        of: find.descendant(of: find.byType(PluginToolCard), matching: find.byType(GlassSurface)),
        matching: find.byType(InkWell),
      );
      expect(card.evaluate().where((e) => (e.widget as InkWell).onTap != null), isEmpty);
    });

    group('insert rows', () {
      final suggestions = {
        'type': 'stack',
        'title': '下一步',
        'children': [
          {
            'type': 'list',
            'items': [
              {'title': '写发布说明', 'subtitle': '草稿', 'insert': '请起草 v1.2 的发布说明'},
              {'title': '只看看', 'subtitle': '没有 insert'},
            ],
          },
        ],
      };

      Future<FakeComposer> pumpWithComposer(WidgetTester tester, Object view) async {
        final composer = FakeComposer();
        usePhoneView(tester);
        await tester.pumpWidget(
          testApp(
            withComposer(
              composer,
              Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ToolRow(
                    key: const ValueKey('ins'),
                    item: weather('ins', meta: {'dsh-go/view': view}),
                    card: ToolCardPlacement.inline,
                    onRespond: _noRespond,
                  ),
                ),
              ),
            ),
          ),
        );
        await pumpFrames(tester);
        return composer;
      }

      testWidgets('a tap puts the row text in the composer, once, without sending', (tester) async {
        final composer = await pumpWithComposer(tester, suggestions);
        await tester.tap(inRow('ins', find.text('写发布说明')));
        await pumpFrames(tester);
        expect(composer.inserted, ['请起草 v1.2 的发布说明']);
        // A row without the field stays read-only.
        await tester.tap(inRow('ins', find.text('只看看')));
        await pumpFrames(tester);
        expect(composer.inserted, hasLength(1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('without a composer to lend, the row is read-only', (tester) async {
        await pumpRows(tester, [
          weather('ro', meta: {'dsh-go/view': suggestions}),
        ]);
        expect(inRow('ro', find.text('写发布说明')), findsOneWidget);
        final taps = find.descendant(
          of: find.descendant(of: find.byType(PluginToolCard), matching: find.byType(GlassSurface)),
          matching: find.byType(InkWell),
        );
        expect(taps.evaluate().where((e) => (e.widget as InkWell).onTap != null), isEmpty);
      });

      testWidgets('a bad insert is dropped and the row is read-only', (tester) async {
        final composer = await pumpWithComposer(tester, {
          'type': 'list',
          'items': [
            {'title': '空白', 'insert': '  '},
            {'title': '太长', 'insert': 'x' * 2001},
            {'title': '数字', 'insert': 5},
          ],
        });
        for (final title in ['空白', '太长', '数字']) {
          await tester.tap(inRow('ins', find.text(title)));
          await pumpFrames(tester);
        }
        expect(composer.inserted, isEmpty);
      });

      test('only the tool card profile reads the field', () {
        final view = {
          'type': 'list',
          'items': [
            {'title': 'a', 'insert': 'hello'},
          ],
        };
        DshUiListItem first(DshUiParse parse) {
          final root = (parse as DshUiParsed).view.root as DshUiList;
          return root.items.single;
        }

        expect(first(parsePluginView(view, budget: PluginViewBudget.toolCard)).insert, 'hello');
        expect(first(parsePluginView(view, budget: PluginViewBudget.panel)).insert, isNull);
        final bad = parsePluginView({
          'type': 'list',
          'items': [
            {'title': 'a', 'insert': 7},
          ],
        }, budget: PluginViewBudget.toolCard);
        expect(first(bad).insert, isNull);
        expect((bad as DshUiParsed).view.issues.single.path, 'view.items[0].insert');
      });
    });

    testWidgets('a session log written by DSH 0.2.1-rc.2', (tester) async {
      // fixtures/live_tool_card.jsonl: a real `dsh headless` run (fake model,
      // a plugin tool with presentationMeta), system prompts and paths
      // removed. The tool result's data.meta is presentationMeta's value.
      final transcript = ChatTranscript();
      for (final line in File('test/plugins/view/fixtures/live_tool_card.jsonl').readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        transcript.apply(SessionLogEvent.fromJson(jsonDecode(line)));
      }
      final item = transcript.items.whereType<ToolChatItem>().single;
      expect(item.name, 'weather_card');
      expect((item.meta as Map)['other'], 'kept');
      await pumpRows(tester, [item]);
      expect(inRow(item.callId, find.text('东京 · 今天')), findsOneWidget);
      expect(inRow(item.callId, find.text('14°')), findsOneWidget);
      expect(inRow(item.callId, find.text('降水概率')), findsOneWidget);
    });

    testWidgets('history: the card is back after reloading the session', (tester) async {
      await pumpRows(tester, [
        replayed({'dsh-go/view': weatherCard, 'other': 1}),
      ]);
      expect(inRow('call-1', find.text('东京 · 未来 3 天')), findsOneWidget);
      expect(inRow('call-1', find.text('21°')), findsOneWidget);
    });
  });
}
