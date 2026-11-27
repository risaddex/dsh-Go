import 'dart:async';

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/composer_insert.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/plugins/deck/deck_panel_view.dart';
import 'package:dsh_app/ui/plugins/seats/session_plugins_tab.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'deck_panel_test.dart' show FakeDeckCarrier, FakeDeckReader, overrides;

FakeDeckReader _workflowReader() => FakeDeckReader()
  ..ticketResult = const DeckTicketDetail(
    key: '84',
    number: 84,
    title: 'Show the panel',
    state: 'OPEN',
    url: 'javascript:alert(1)',
    labels: [],
    body: '',
    acceptanceCriteria: [],
    progress: DeckProgress(percent: null, note: '', updatedAt: null),
    blockedBy: [],
    actions: [DeckTicketAction(id: 'implement', label: 'Implement', prompt: '/implement #84')],
  );

class _WorkflowWorkspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState(
    status: WorkspacesStatus.ready,
    workspaces: [
      Workspace(workspaceId: 'source', path: '/source', title: 'Source', sessionIds: ['s1']),
      Workspace(workspaceId: 'unrelated', path: '/unrelated', title: 'Unrelated', sessionIds: []),
    ],
  );
}

class _WorkflowCarrier extends FakeDeckCarrier {
  _WorkflowCarrier() : super({deckPanelReadFeature});

  final calls = <(String, Map<String, Object?>)>[];
  final created = Completer<RpcResult>();

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) {
    if (endpoint == 'session/list') return Future.value(const RpcOk({'items': []}));
    calls.add((endpoint, args));
    return created.future;
  }
}

Future<ProviderContainer> _openWorkflow(
  WidgetTester tester,
  _WorkflowCarrier carrier, {
  bool oneShot = false,
  FakeDeckReader? reader,
}) async {
  usePhoneView(tester);
  final client = DshClient.withCarrier(carrier);
  addTearDown(client.close);
  await tester.pumpWidget(
    testApp(
      const Scaffold(body: SessionPluginsTab(sessionId: 's1')),
      overrides: [
        ...overrides(reader ?? _workflowReader()),
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(client: client, label: 'box', isLocal: false)),
        ),
        workspacesProvider.overrideWith(_WorkflowWorkspaces.new),
        if (oneShot)
          subagentParentProvider('s1').overrideWithValue(
            const SubagentParent(
              address: SubagentAddress(parentSessionId: 'parent', childSessionId: 's1', mode: SubagentMode.oneShot),
              label: 'child',
              parentTitle: 'parent',
            ),
          ),
      ],
    ),
  );
  await pumpFrames(tester);
  final scope = ProviderScope.containerOf(tester.element(find.byType(DeckPanelView)));
  scope.read(currentSessionProvider.notifier).select('s1');
  final prefs = scope.read(workspacePrefsProvider.notifier);
  await prefs.selection();
  await prefs.select('unrelated');
  expect(scope.read(workspacePrefsProvider).selected, 'unrelated');
  await tester.tap(find.text('#84 Show the panel'));
  await pumpFrames(tester);
  await tester.tap(find.text('Implement'));
  await tester.pumpAndSettle();
  return scope;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('panel in 对话详情 › 插件', () {
    testWidgets('a host workflow requests a draft for this chat without writing to the tracker', (tester) async {
      final reader = _workflowReader();
      final carrier = _WorkflowCarrier();
      final container = await _openWorkflow(tester, carrier, reader: reader);
      expect(find.text('在跟踪器中打开'), findsNothing);
      await tester.tap(find.text('用作对话草稿'));
      await tester.pumpAndSettle();
      final draft = container.read(composerInsertProvider);
      expect((draft?.sessionId, draft?.token, draft?.replaceDraft), ('s1', '/implement #84', true));
      expect(reader.ticketCalls, [('s1', '84')]);
    });

    testWidgets('new workflow creates one blank session in the source workspace without changing preferences', (
      tester,
    ) async {
      final carrier = _WorkflowCarrier();
      final scope = await _openWorkflow(tester, carrier);
      await tester.tap(find.text('在新对话中起草'));
      await pumpFrames(tester);
      expect(carrier.calls.map((call) => call.$1), ['session/create']);
      expect(carrier.calls.single.$2, {
        'request': {'workspaceId': 'source'},
      });
      expect(scope.read(composerInsertProvider), isNull);
      carrier.created.complete(const RpcOk({'sessionId': 'actual-new-chat'}));
      await pumpFrames(tester);
      final draft = scope.read(composerInsertProvider);
      expect((draft?.sessionId, draft?.token), ('actual-new-chat', '/implement #84'));
      expect(scope.read(workspacePrefsProvider).selected, 'unrelated');
      expect(carrier.calls, hasLength(1), reason: 'no prompt was sent');
    });

    testWidgets('a delayed workflow result cannot draft in a different host', (tester) async {
      final carrier = _WorkflowCarrier();
      final scope = await _openWorkflow(tester, carrier);
      await tester.tap(find.text('在新对话中起草'));
      await pumpFrames(tester);
      expect(carrier.calls, hasLength(1));
      scope.read(activeHostProvider.notifier).select(const HostRef.ssh('replacement'));
      scope.read(currentSessionProvider.notifier).select('s1');
      carrier.created.complete(const RpcOk({'sessionId': 'actual-new-chat'}));
      await pumpFrames(tester);
      expect(scope.read(composerInsertProvider), isNull);
      expect(scope.read(currentSessionProvider), 's1');
    });

    testWidgets('a rejected source workspace never falls back to another workspace', (tester) async {
      final carrier = _WorkflowCarrier();
      final scope = await _openWorkflow(tester, carrier);
      await tester.tap(find.text('在新对话中起草'));
      await pumpFrames(tester);
      carrier.created.complete(const RpcError(DshRemoteException('workspace/not-found', 'source was removed')));
      await pumpFrames(tester);
      expect(carrier.calls.map((call) => call.$1), ['session/create']);
      expect(carrier.calls.single.$2, {
        'request': {'workspaceId': 'source'},
      });
      expect(scope.read(workspacePrefsProvider).selected, 'unrelated');
      expect(scope.read(composerInsertProvider), isNull);
      expect(find.text('新建对话失败'), findsOneWidget);
      expect(find.text('Implement'), findsOneWidget);
    });

    testWidgets('one-shot chat offers copy and new workflow but not current draft', (tester) async {
      final carrier = _WorkflowCarrier();
      await _openWorkflow(tester, carrier, oneShot: true);
      expect(find.text('用作对话草稿'), findsNothing);
      expect(find.text('在新对话中起草'), findsOneWidget);
      expect(find.text('复制提示词'), findsOneWidget);
    });
  });
}
