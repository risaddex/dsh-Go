// The deck's panel must also sit in the side panel a left swipe pulls in (the
// 信息/插件 pair), not only in 对话详情's 插件 tab. The side panel builds its own
// list of plugin panes, so that list is what this checks: the deck is one entry
// while the connected host announced `deck.panel.read.v1`, and no entry at all
// when it did not.

import 'package:dsh_app/plugins/deck/deck_panel_state.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/plugins/seams/seat_models.dart';
import 'package:dsh_app/plugins/seams/seat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/deck/deck_panel_view.dart';
import 'package:dsh_app/ui/plugins/native/chat_plugins_sheet.dart';
import 'package:dsh_app/ui/plugins/seats/session_plugins_tab.dart';
import 'package:dsh_app/ui/session/conversation_panel.dart';
import 'package:dsh_app/ui/session/conversation_panes.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';

/// A tree reply the client accepts, so the panel has something to draw. [tickets] children
/// under the one spec: enough of them make the panel taller than the screen.
Map<String, Object?> _treeReply({int tickets = 1}) => {
  'ok': true,
  'sessionId': 's1',
  'containers': [
    {
      'key': '70',
      'kind': 'spec',
      'title': 'Spec over the side panel',
      'state': 'OPEN',
      'tickets': [
        for (var i = 0; i < tickets; i++)
          {
            'key': '${93 + i}',
            'title': tickets == 1 ? 'Side panel entry' : 'Ticket ${93 + i}',
            'state': 'OPEN',
            'url': '',
          },
      ],
    },
  ],
  'truncated': false,
  'omittedContainers': 0,
  'omittedTickets': 0,
};

/// A carrier that only reports the features its Host announces, and answers
/// the deck read with one container.
class _Carrier extends DshCarrier {
  _Carrier(this.capabilities, {this.tickets = 1});

  final Set<String> capabilities;
  final int tickets;

  @override
  Set<String>? get peerCapabilities => capabilities;

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async =>
      endpoint == 'deck.panel.read' ? RpcOk(_treeReply(tickets: tickets)) : throw const DshTransportException('not used');

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw const DshTransportException('not used');

  @override
  Future<void> close() async {}
}

const _seat = SeatContext(host: HostRef.local, sessionId: 's1', placement: SeatPlacement.panel);

/// Everything the side panel reads, except the deck, stubbed empty.
List<Override> _overrides({required Set<String> announced, int tickets = 1}) {
  final client = DshClient.withCarrier(_Carrier(announced, tickets: tickets));
  addTearDown(client.close);
  return [
    activeConnectionProvider.overrideWithValue(
      AsyncData(HostConnection(client: client, label: 'relay', isLocal: false)),
    ),
    chatWebPluginsProvider('s1').overrideWith((ref) => const ChatWebPlugins(seat: _seat)),
    nativePanelsProvider.overrideWithValue(const []),
    sessionPluginPlanProvider('s1').overrideWith((ref) => const SeatPlan(_seat, [])),
  ];
}

void main() {
  test('the side panel lists the deck while the host announced the feature', () {
    final c = ProviderContainer(overrides: _overrides(announced: {deckPanelReadFeature}));
    addTearDown(c.dispose);
    final panes = c.read(conversationPluginPanesProvider('s1'));
    expect(panes.map((p) => p.id), ['deck']);
    expect(panes.single.label(), isNotEmpty);
  });

  test('and has no deck entry when it did not, so the panel stays as it was', () {
    final c = ProviderContainer(overrides: _overrides(announced: {'harness.remote.v3'}));
    addTearDown(c.dispose);
    expect(c.read(conversationPluginPanesProvider('s1')), isEmpty);
  });

  testWidgets('the side panel draws the deck, not the empty notice', (tester) async {
    await loadTestFonts();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        Scaffold(body: ConversationPanel(sessionId: 's1', onOpen: _ignore)),
        overrides: _overrides(announced: {deckPanelReadFeature}),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('插件').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DeckPanelView), findsOneWidget);
    expect(find.textContaining('Spec over the side panel'), findsOneWidget);
  });

  // #98: a tree taller than the screen must scroll inside the side panel. The panel's
  // body used to be a plain Column in a bounded box, so the rows ran past the bottom of
  // the screen over the shortcut row, with nothing to scroll.
  testWidgets('a tree taller than the screen scrolls inside the side panel', (tester) async {
    await loadTestFonts();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        Scaffold(body: ConversationPanel(sessionId: 's1', onOpen: _ignore)),
        overrides: _overrides(announced: {deckPanelReadFeature}, tickets: 40),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('插件').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'the rows must not overflow the panel');
    final last = find.textContaining('Ticket 132');
    await tester.scrollUntilVisible(
      last,
      300,
      scrollable: find.ancestor(of: find.byType(DeckPanelView), matching: find.byType(Scrollable)).first,
    );
    expect(last, findsOneWidget);
  });
}

void _ignore(Object? _) {}
