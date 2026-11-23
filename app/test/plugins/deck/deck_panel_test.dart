// The deck's read-only panel (spec #70, deck.panel.read.v1) in 对话详情's
// 「插件」 tab: it exists only for a host that announced the feature; it reads
// the tree on open and on Refresh, one ticket per open, never polls or caches;
// a tree failure replaces the content, a ticket failure keeps the tree; and it
// has no write control. The reads are scripted; the wire is tested in
// packages/dsh_client and packages/dsh_remote.

import 'dart:async';

import 'package:dsh_app/plugins/deck/deck_panel_state.dart';
import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/deck/deck_panel_view.dart';
import 'package:dsh_app/ui/plugins/seats/session_plugins_tab.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import '../native/support.dart';

DeckTreeTicket ticket(
  String key,
  String title, {
  String state = 'OPEN',
  List<DeckBlocker>? blockedBy = const [],
}) => DeckTreeTicket(key: key, number: int.tryParse(key), title: title, state: state, url: '', blockedBy: blockedBy);

DeckTree deckTree({
  List<DeckContainer>? containers,
  bool truncated = false,
  int omittedContainers = 0,
  int omittedTickets = 0,
}) => DeckTree(
  sessionId: 's1',
  containers:
      containers ??
      [
        DeckContainer(
          key: '70',
          number: 70,
          kind: DeckContainerKind.spec,
          title: 'Deck over remote',
          state: 'OPEN',
          url: '',
          tickets: [
            ticket('83', 'Forward the reads'),
            ticket('84', 'Show the panel', blockedBy: const [DeckBlocker(key: '83', state: 'OPEN')]),
            ticket('85', 'Unknown blockers', blockedBy: null),
            ticket('71', 'Already shipped', state: 'CLOSED'),
          ],
        ),
        const DeckContainer(
          key: '56',
          number: 56,
          kind: DeckContainerKind.map,
          title: 'Linear room parity',
          state: 'OPEN',
          url: '',
          tickets: [],
        ),
      ],
  truncated: truncated,
  omittedContainers: omittedContainers,
  omittedTickets: omittedTickets,
);

const detail = DeckTicketDetail(
  key: '84',
  number: 84,
  title: 'Show the panel',
  state: 'OPEN',
  status: 'ready-for-agent',
  url: '',
  labels: [DeckLabel(name: 'enhancement', color: '00ff00')],
  body: 'Render the tree and the ticket.',
  acceptanceCriteria: [
    DeckAcceptanceItem(text: 'Shows the tree', done: true),
    DeckAcceptanceItem(text: 'Shows a ticket', done: false),
  ],
  progress: DeckProgress(percent: 40, note: 'Client layer done', updatedAt: null),
  blockedBy: [DeckBlocker(key: '83', title: 'Forward the reads', state: 'OPEN')],
);

/// Scripted reads that count every call.
class FakeDeckReader implements DeckPanelReader {
  final treeCalls = <String>[];
  final ticketCalls = <(String, String)>[];
  Object treeResult = deckTree();
  Object ticketResult = detail;

  /// When set, the next tree read waits for it.
  Completer<void>? treeGate;

  @override
  Future<DeckTree> tree(String sessionId) async {
    treeCalls.add(sessionId);
    await treeGate?.future;
    final result = treeResult;
    if (result is DeckTree) return result;
    throw result;
  }

  @override
  Future<DeckTicketDetail> ticket(String sessionId, String key) async {
    ticketCalls.add((sessionId, key));
    final result = ticketResult;
    if (result is DeckTicketDetail) return result;
    throw result;
  }
}

class _Installed extends InstalledPluginsController {
  @override
  Future<List<PluginBundle>?> build() async => const [];
}

class _NoSettings extends EngineSettingsController {
  @override
  Future<EngineSettings?> build() async => null;
}

/// A tunnel-like carrier that only announces features.
class _Carrier extends DshCarrier {
  _Carrier(this.capabilities);

  final Set<String>? capabilities;

  @override
  Set<String>? get peerCapabilities => capabilities;

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw const DshTransportException('not used');

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw const DshTransportException('not used');

  @override
  Future<void> close() async {}
}

ProviderContainer container(Set<String>? capabilities) {
  final client = DshClient.withCarrier(_Carrier(capabilities));
  addTearDown(client.close);
  final c = ProviderContainer(
    overrides: [
      activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, label: 'relay', isLocal: false))),
      installedPluginsProvider.overrideWith(_Installed.new),
      webBootProvider.overrideWith((ref) async => null),
      bridgeInventoryProvider.overrideWith((ref) async => null),
      engineSettingsProvider.overrideWith(_NoSettings.new),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<SeatInventory?> inventoryOf(ProviderContainer c) async {
  c.listen(seatInventoryProvider, (_, _) {});
  await c.read(installedPluginsProvider.future);
  await c.read(webBootProvider.future);
  await c.read(bridgeInventoryProvider.future);
  await c.read(engineSettingsProvider.future);
  return c.read(seatInventoryProvider);
}

List<Override> overrides(FakeDeckReader? reader) => [
  ...nativeOverrides(FakeBridge()),
  deckPanelReaderProvider.overrideWithValue(reader),
  seatInventoryProvider.overrideWith((ref) => SeatInventory(deckPanel: reader != null)),
  islandBudgetProvider.overrideWithValue(const NoIslandBudget()),
];

Future<void> openTab(WidgetTester tester, FakeDeckReader? reader) async {
  await tester.pumpWidget(testApp(const Scaffold(body: SessionPluginsTab(sessionId: 's1')), overrides: overrides(reader)));
  await pumpFrames(tester);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('feature negotiation', () {
    test('a host that announced deck.panel.read.v1 has a reader and a seat in the Plugins tab', () async {
      final c = container({'harness.remote.v3', deckPanelReadFeature});
      expect(c.read(deckPanelReaderProvider), isNotNull);
      final seats = (await inventoryOf(c))!.occupantsFor(Slots.rightPaneTab);
      expect(seats.map((o) => o.cell), [SeatInventory.deckPanelCell]);
      final items = SlotAdapterRegistry.standard().plan(
        Slots.rightPaneTab,
        seats,
        const SeatContext(host: HostRef.local, sessionId: 's1', placement: SeatPlacement.page),
        budget: const NoIslandBudget(),
        overrides: SeatOverrides.none,
        inventory: (await inventoryOf(c))!,
      );
      expect([for (final i in items) (i.mode, i.adapter?.id)], [(SeatMode.native, 'deck-panel')]);
    });

    test('a host that did not announce it, or a carrier with no negotiation, has neither', () async {
      for (final capabilities in [<String>{'harness.remote.v3'}, null]) {
        final c = container(capabilities);
        expect(c.read(deckPanelReaderProvider), isNull, reason: '$capabilities');
        expect((await inventoryOf(c))!.occupantsFor(Slots.rightPaneTab), isEmpty, reason: '$capabilities');
      }
    });

    test('ui.json hiding the deck package hides the panel', () async {
      final c = container({deckPanelReadFeature});
      final inventory = (await inventoryOf(c))!;
      final items = SlotAdapterRegistry.standard().plan(
        Slots.rightPaneTab,
        inventory.occupantsFor(Slots.rightPaneTab),
        const SeatContext(host: HostRef.local, sessionId: 's1', placement: SeatPlacement.page),
        budget: const NoIslandBudget(),
        overrides: SeatOverrides({
          Slots.rightPaneTab: {SeatInventory.deckPackage: SeatOverride.hidden},
        }),
        inventory: inventory,
      );
      expect(items.single.mode, SeatMode.hidden);
    });
  });

  group('panel in 对话详情 › 插件', () {
    testWidgets('a host without the feature shows no panel, no empty screen, no error row', (tester) async {
      usePhoneView(tester);
      await openTab(tester, null);
      expect(find.byType(DeckPanelView), findsNothing);
      expect(find.text('Deck'), findsNothing);
      expect(find.byIcon(Icons.error), findsNothing);
      expect(find.byType(Text), findsNothing, reason: 'the tab has nothing to say');
    });

    testWidgets('opening reads the tree once, for this session id only', (tester) async {
      usePhoneView(tester);
      final reader = FakeDeckReader();
      await openTab(tester, reader);
      expect(find.byType(DeckPanelView), findsOneWidget);
      expect(reader.treeCalls, ['s1']);
      expect(reader.ticketCalls, isEmpty);
    });

    testWidgets('maps and specs are told apart; tickets show state, blockers and free-to-pick-up', (tester) async {
      usePhoneView(tester);
      await openTab(tester, FakeDeckReader());
      expect(find.text('规格'), findsOneWidget);
      expect(find.text('地图'), findsOneWidget);
      expect(find.text('#70 Deck over remote'), findsOneWidget);
      expect(find.text('#56 Linear room parity'), findsOneWidget);
      expect(find.text('#83 Forward the reads'), findsOneWidget);
      // Free: only the open one with no open blocker.
      expect(find.text('可接手'), findsOneWidget);
      expect(find.text('被 #83 阻塞'), findsOneWidget);
      expect(find.text('已关闭'), findsOneWidget);
      // Unknown blockers are never presented as free.
      expect(find.text('#85 Unknown blockers'), findsOneWidget);
      expect(find.text('不完整'), findsNothing);
    });

    testWidgets('a whole tree carries no truncation notice', (tester) async {
      usePhoneView(tester);
      await openTab(tester, FakeDeckReader());
      expect(find.textContaining('这不是完整的树'), findsNothing);
    });

    testWidgets('a tree the deck cut at its limit says so', (tester) async {
      usePhoneView(tester);
      await openTab(tester, FakeDeckReader()..treeResult = deckTree(truncated: true, omittedContainers: 3, omittedTickets: 9));
      expect(find.textContaining('这不是完整的树'), findsOneWidget);
    });

    testWidgets('an empty workspace shows a deliberate empty state', (tester) async {
      usePhoneView(tester);
      await openTab(tester, FakeDeckReader()..treeResult = deckTree(containers: const []));
      expect(find.text('这个工作区没有打开的地图或规格'), findsOneWidget);
      expect(find.textContaining('无法读取'), findsNothing);
    });

    testWidgets('a ticket opens to its detail with one read; Back returns to the loaded tree without reading it', (
      tester,
    ) async {
      usePhoneView(tester);
      final reader = FakeDeckReader();
      await openTab(tester, reader);

      await tester.tap(find.text('#84 Show the panel'));
      await pumpFrames(tester);
      expect(reader.ticketCalls, [('s1', '84')]);
      expect(find.text('Render the tree and the ticket.'), findsOneWidget);
      expect(find.text('enhancement'), findsOneWidget);
      expect(find.text('ready-for-agent'), findsOneWidget);
      expect(find.text('Shows the tree'), findsOneWidget);
      expect(find.text('Client layer done'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(find.textContaining('Forward the reads'), findsOneWidget);
      expect(find.text('#70 Deck over remote'), findsNothing, reason: 'the detail replaces the tree');

      await tester.tap(find.text('返回'));
      await pumpFrames(tester);
      expect(find.text('#70 Deck over remote'), findsOneWidget);
      expect(reader.treeCalls, ['s1'], reason: 'Back shows the tree already read');
    });

    testWidgets('Refresh reads the tree again; opening a ticket again reads it again; nothing polls', (tester) async {
      usePhoneView(tester);
      final reader = FakeDeckReader();
      await openTab(tester, reader);

      await tester.tap(find.byTooltip('刷新'));
      await pumpFrames(tester);
      expect(reader.treeCalls, hasLength(2));

      await tester.tap(find.text('#84 Show the panel'));
      await pumpFrames(tester);
      await tester.tap(find.text('返回'));
      await pumpFrames(tester);
      await tester.tap(find.text('#84 Show the panel'));
      await pumpFrames(tester);
      expect(reader.ticketCalls, hasLength(2), reason: 'no cache between interactions');

      await tester.pump(const Duration(hours: 1));
      expect((reader.treeCalls.length, reader.ticketCalls.length), (2, 2), reason: 'no timer, no polling');
    });

    testWidgets('a tree failure replaces the content with an error and Retry', (tester) async {
      usePhoneView(tester);
      final reader = FakeDeckReader()..treeResult = const DshRemoteException('timeout', 'The deck read did not finish in time');
      await openTab(tester, reader);
      expect(find.text('无法读取 Deck'), findsOneWidget);
      expect(find.text('#70 Deck over remote'), findsNothing);

      reader.treeResult = deckTree();
      await tester.tap(find.text('重试'));
      await pumpFrames(tester);
      expect(reader.treeCalls, hasLength(2));
      expect(find.text('#70 Deck over remote'), findsOneWidget);
      expect(find.text('无法读取 Deck'), findsNothing);
    });

    testWidgets('a malformed reply is a failure too', (tester) async {
      usePhoneView(tester);
      await openTab(tester, FakeDeckReader()..treeResult = const DshProtocolException('deck panel reply: another session'));
      expect(find.text('无法读取 Deck'), findsOneWidget);
    });

    testWidgets('a ticket failure stays in the detail and keeps the loaded tree', (tester) async {
      usePhoneView(tester);
      final reader = FakeDeckReader()..ticketResult = const DshRemoteException('not-found', 'The deck read failed');
      await openTab(tester, reader);

      await tester.tap(find.text('#84 Show the panel'));
      await pumpFrames(tester);
      expect(find.text('无法读取这张票'), findsOneWidget);
      expect(find.text('无法读取 Deck'), findsNothing, reason: 'the tree is not what failed');

      await tester.tap(find.text('返回'));
      await pumpFrames(tester);
      expect(find.text('#70 Deck over remote'), findsOneWidget);
      expect(reader.treeCalls, ['s1'], reason: 'the tree was kept, not read again');
    });

    testWidgets('a slow tree read shows loading, and a refresh in the meantime is not stacked', (tester) async {
      usePhoneView(tester);
      final reader = FakeDeckReader()..treeGate = Completer<void>();
      await openTab(tester, reader);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('刷新'), warnIfMissed: false);
      await pumpFrames(tester);
      expect(reader.treeCalls, hasLength(1), reason: 'Refresh is off while a read is in flight');
      reader.treeGate!.complete();
      await pumpFrames(tester);
      expect(find.text('#70 Deck over remote'), findsOneWidget);
    });

    testWidgets('read-only: no field, no write or comment control, no prompt control', (tester) async {
      usePhoneView(tester);
      await openTab(tester, FakeDeckReader());
      await tester.tap(find.text('#84 Show the panel'));
      await pumpFrames(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(Checkbox), findsNothing, reason: 'acceptance items are shown, not toggled');
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
      // The only controls are Back and (on the tree) Refresh.
      expect(find.byType(TextButton), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('a small phone with long titles does not overflow', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(640, 1280);
      addTearDown(tester.view.reset);
      final long = 'A very long ticket title that keeps going well past one line on a narrow phone ' * 2;
      await openTab(
        tester,
        FakeDeckReader()
          ..treeResult = deckTree(
            containers: [
              DeckContainer(
                key: 'OMB-1234',
                number: null,
                kind: DeckContainerKind.map,
                title: long,
                state: 'OPEN',
                url: '',
                tickets: [ticket('OMB-1235', long, blockedBy: [const DeckBlocker(key: 'OMB-1200', state: 'OPEN'), const DeckBlocker(key: 'OMB-1201', state: 'OPEN')])],
              ),
            ],
          ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.textContaining('OMB-1235'));
      await pumpFrames(tester);
      expect(tester.takeException(), isNull);
    });
  });
}