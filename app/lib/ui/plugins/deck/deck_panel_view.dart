// The deck panel (deck.panel.read.v1) in the conversation's Plugins tab:
// open maps and specs with their tickets, optional standalone tickets, and
// one ticket's detail on demand.
//
// What it reads, and when: the tree once when it opens and again only when
// the person taps Refresh; one ticket each time one is opened. What it read
// lives in this widget's state alone: no cache between interactions, no timer,
// no polling. Going back from a ticket shows the tree already read. Optional
// workflow prompts only prepare a draft; this view never sends or writes to the tracker.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/deck/deck_panel_state.dart';
import '../../../state/agents_state.dart';
import '../../../state/composer_insert.dart';
import '../../../state/hosts_state.dart';
import '../../../state/read_list_identity.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';
import '../../common/app_sheet.dart' show groupTitleStyle;
import '../../common/label_chip.dart';
import '../../common/empty_view.dart';
import '../../common/list_page_row.dart';
import '../../common/status_chip.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'deck_panel_comments.dart';
import 'deck_ticket_controls.dart';
import 'deck_tree_filter.dart';
import 'deck_tree_toolbar.dart';

class DeckPanelView extends ConsumerStatefulWidget {
  const DeckPanelView({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<DeckPanelView> createState() => _DeckPanelViewState();
}

class _DeckPanelViewState extends ConsumerState<DeckPanelView> {
  AsyncValue<DeckTree> _tree = const AsyncLoading();
  final _treeSearch = TextEditingController();
  DeckTreeStatus _treeStatus = DeckTreeStatus.all;
  DeckTreeOrder _treeOrder = DeckTreeOrder.host;

  /// The ticket whose detail is showing; null shows the tree.
  String? _openKey;
  AsyncValue<DeckTicketDetail> _ticket = const AsyncLoading();

  /// Which read a reply belongs to: a reply that is not the latest one of its
  /// kind (a refresh, another ticket, Back in the meantime) is dropped.
  int _treeRun = 0;
  int _ticketRun = 0;
  bool _creatingDraftSession = false;

  @override
  void initState() {
    super.initState();
    _startTree();
  }

  @override
  void didUpdateWidget(DeckPanelView old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) {
      _resetTreeNavigation();
      _openKey = null;
      _ticketRun++;
      _startTree();
    }
  }

  @override
  void dispose() {
    _treeSearch.dispose();
    super.dispose();
  }

  void _resetTreeNavigation() {
    _treeSearch.clear();
    _treeStatus = DeckTreeStatus.all;
    _treeOrder = DeckTreeOrder.host;
  }

  void _startTree() {
    final run = ++_treeRun;
    _tree = const AsyncLoading();
    _readTree(run);
  }

  Future<void> _readTree(int run) async {
    final reader = ref.read(deckPanelReaderProvider);
    if (reader == null) return;
    AsyncValue<DeckTree> result;
    try {
      result = AsyncData(await reader.tree(widget.sessionId));
    } on Object catch (e, s) {
      result = AsyncError(e, s);
    }
    if (mounted && run == _treeRun && identical(ref.read(deckPanelReaderProvider), reader)) {
      setState(() => _tree = result);
    }
  }

  void _openTicket(String key) {
    final run = ++_ticketRun;
    setState(() {
      _openKey = key;
      _ticket = const AsyncLoading();
    });
    _readTicket(key, run);
  }

  Future<void> _readTicket(String key, int run) async {
    final reader = ref.read(deckPanelReaderProvider);
    if (reader == null) return;
    AsyncValue<DeckTicketDetail> result;
    try {
      result = AsyncData(await reader.ticket(widget.sessionId, key));
    } on Object catch (e, s) {
      result = AsyncError(e, s);
    }
    if (mounted && run == _ticketRun && identical(ref.read(deckPanelReaderProvider), reader)) {
      setState(() => _ticket = result);
    }
  }

  void _back() => setState(() {
    _openKey = null;
    _ticketRun++;
  });

  @override
  Widget build(BuildContext context) {
    ref.listen(deckPanelReaderProvider, (previous, next) {
      if (identical(previous, next)) return;
      _resetTreeNavigation();
      _openKey = null;
      _ticketRun++;
      _ticket = const AsyncLoading();
      _startTree();
    });
    if (ref.watch(deckPanelReaderProvider) == null) return const SizedBox.shrink();
    final open = _openKey;
    return PopScope(
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: open == null ? _treeChildren(context) : _detailChildren(context, open),
      ),
    );
  }

  List<Widget> _treeChildren(BuildContext context) {
    final l10n = context.l10n;
    return [
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: IconButton(
          tooltip: l10n.deckPanelRefresh,
          icon: const Icon(AppIcons.refresh),
          onPressed: _tree.isLoading ? null : () => setState(_startTree),
        ),
      ),
      _tree.when(
        loading: () => const _Loading(),
        error: (_, _) => EmptyView(
          icon: AppIcons.error,
          title: l10n.deckPanelTreeError,
          actionLabel: l10n.deckPanelRetry,
          onAction: () => setState(_startTree),
        ),
        data: (tree) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DeckTreeToolbar(
              search: _treeSearch,
              onSearchChanged: (_) => setState(() {}),
              status: _treeStatus,
              onStatusChanged: (status) => setState(() => _treeStatus = status),
              order: _treeOrder,
              onOrderChanged: (order) => setState(() => _treeOrder = order),
            ),
            _TreeBody(tree: tree, query: _treeSearch.text, status: _treeStatus, order: _treeOrder, onOpen: _openTicket),
          ],
        ),
      ),
    ];
  }

  String? _workspaceId(WorkspacesState registry) {
    for (final workspace in registry.workspaces) {
      if (workspace.sessionIds.contains(widget.sessionId)) return workspace.workspaceId;
    }
    return null;
  }

  Future<void> _useDraft(String prompt, {required bool fresh, required int run}) async {
    if (!mounted || run != _ticketRun || _creatingDraftSession || ModalRoute.of(context)?.isCurrent != true) return;
    final sessionId = widget.sessionId;
    final container = ProviderScope.containerOf(context, listen: false);
    final host = ref.read(activeHostProvider);
    final connection = ref.read(readListLiveConnectionProvider);
    if (connection == null) return;
    final origin = ComposerInsertOrigin(
      host,
      connection,
      sessionId,
      ref.read(currentSessionProvider.notifier).selectionRevision,
    );
    final reader = ref.read(deckPanelReaderProvider);
    final workspaceId = fresh ? _workspaceId(ref.read(workspacesProvider)) : null;
    bool visible() => mounted && run == _ticketRun && ModalRoute.of(context)?.isCurrent == true;
    bool current() => visible() && origin.current(container) && identical(ref.read(deckPanelReaderProvider), reader);
    bool sameWorkspace() => workspaceId == _workspaceId(ref.read(workspacesProvider));
    void showFailure() =>
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.chatCreateFailed)));

    if (!current()) return;
    var target = sessionId;
    if (fresh) {
      if (workspaceId == null) return;
      setState(() => _creatingDraftSession = true);
      try {
        target = (await connection.client.createSession(workspaceId: workspaceId)).sessionId;
        if (!current()) return;
        if (!sameWorkspace() || target.isEmpty) {
          showFailure();
          return;
        }
      } on Object {
        if (current()) showFailure();
        return;
      } finally {
        if (mounted) setState(() => _creatingDraftSession = false);
      }
    } else if (ref.read(subagentParentProvider(sessionId))?.address.mode == SubagentMode.oneShot) {
      return;
    }
    _back();
    Navigator.of(context).popUntil((route) => route.isFirst);
    container
        .read(composerInsertProvider.notifier)
        .request(ComposerInsert.workflow(prompt, sessionId: target, origin: origin));
  }

  List<Widget> _detailChildren(BuildContext context, String key) {
    final l10n = context.l10n;
    final run = _ticketRun;
    final hasConnection = ref.watch(readListLiveConnectionProvider) != null;
    final workspace = _workspaceId(ref.watch(workspacesProvider));
    final readOnly = ref.watch(
      subagentParentProvider(widget.sessionId).select((p) => p?.address.mode == SubagentMode.oneShot),
    );

    return [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(onPressed: _back, icon: const Icon(AppIcons.back), label: Text(l10n.deckPanelBack)),
      ),
      _ticket.when(
        loading: () => const _Loading(),
        // A ticket failure stays here and the tree behind it is kept; Back is
        // the way out.
        error: (_, _) => EmptyView(icon: AppIcons.error, title: l10n.deckPanelTicketError),
        data: (ticket) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DeckTicketControls(
              ticket: ticket,
              onDraft: !hasConnection || readOnly ? null : (text) => _useDraft(text, fresh: false, run: run),
              onNewDraft: !hasConnection || workspace == null || _creatingDraftSession
                  ? null
                  : (text) => _useDraft(text, fresh: true, run: run),
            ),
            _TicketBody(ticket: ticket),
            DeckPanelComments(sessionId: widget.sessionId, ticketKey: key),
          ],
        ),
      ),
    ];
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: context.l10n.deckPanelLoading),
      ),
    ),
  );
}

String _shortKey(String key) => deckDisplayKey(key);

String _stateLabel(BuildContext context, {required bool closed}) =>
    closed ? context.l10n.deckPanelStateClosed : context.l10n.deckPanelStateOpen;

class _TreeBody extends StatelessWidget {
  const _TreeBody({
    required this.tree,
    required this.query,
    required this.status,
    required this.order,
    required this.onOpen,
  });

  final DeckTree tree;
  final String query;
  final DeckTreeStatus status;
  final DeckTreeOrder order;
  final void Function(String key) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (:groups, :standalone) = filterDeckTree(tree, query: query, status: status, order: order);
    final noRows = groups.isEmpty && (standalone?.isEmpty ?? true);
    final isFiltering = query.trim().isNotEmpty || status != DeckTreeStatus.all;
    final colors = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tree.truncated)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppIcons.warning, size: 18, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(child: Text(l10n.deckPanelTruncated)),
              ],
            ),
          ),
        if (noRows && (isFiltering || !tree.truncated))
          EmptyView(
            icon: AppIcons.todo,
            title: isFiltering
                ? l10n.deckPanelNoMatches
                : (standalone == null ? l10n.deckPanelEmpty : l10n.deckPanelEmptyAll),
            compact: true,
          ),
        if (standalone == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(l10n.deckPanelStandaloneUnavailable),
          ),
        for (final (:container, :tickets) in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Row(
              children: [
                StatusChip(
                  tone: StatusTone.idle,
                  label: container.kind == DeckContainerKind.map ? l10n.deckPanelMap : l10n.deckPanelSpec,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: TextButton(
                      onPressed: () => onOpen(container.key),
                      style: TextButton.styleFrom(alignment: AlignmentDirectional.centerStart),
                      child: Text(
                        '${_shortKey(container.key)} ${container.title}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (tickets.isNotEmpty)
            ListPageCard(
              children: [for (final ticket in tickets) _TicketRow(ticket: ticket, onOpen: onOpen)],
            ),
        ],
        if (standalone != null && standalone.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Semantics(
              header: true,
              child: Text(l10n.deckPanelStandalone, style: Theme.of(context).textTheme.titleSmall),
            ),
          ),
          ListPageCard(
            children: [for (final ticket in standalone) _TicketRow(ticket: ticket, onOpen: onOpen)],
          ),
        ],
      ],
    );
  }
}

class _TicketRow extends StatelessWidget {
  const _TicketRow({required this.ticket, required this.onOpen});

  final DeckTreeTicket ticket;
  final void Function(String key) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final blocking = [for (final b in ticket.openBlockers) _shortKey(b.key)];
    final String? note = ticket.isFree
        ? l10n.deckPanelFree
        : (!ticket.isClosed && blocking.isNotEmpty ? l10n.deckPanelBlockedBy(blocking.join(', ')) : null);
    return ListPageRow(
      title: '${_shortKey(ticket.key)} ${ticket.title}',
      titleMaxLines: 2,
      subtitle: note,
      subtitleMaxLines: 2,
      subtitleColor: ticket.isFree ? DshColors.of(context).success : null,
      meta: _stateLabel(context, closed: ticket.isClosed),
      onTap: () => onOpen(ticket.key),
    );
  }
}

class _TicketBody extends StatelessWidget {
  const _TicketBody({required this.ticket});

  final DeckTicketDetail ticket;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final percent = ticket.progress.percent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${_shortKey(ticket.key)} ${ticket.title}', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusChip(
                tone: ticket.isClosed ? StatusTone.idle : StatusTone.ok,
                label: _stateLabel(context, closed: ticket.isClosed),
              ),
            ],
          ),
          if (ticket.labels.isNotEmpty)
            _Section(
              title: l10n.deckPanelLabels,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final label in ticket.labels) LabelChip(name: label.name, colorHex: label.color)],
              ),
            ),
          _Section(
            title: l10n.deckPanelDescription,
            child: ticket.body.trim().isEmpty ? Text(l10n.deckPanelNoDescription) : SelectableText(ticket.body),
          ),
          if (ticket.acceptanceCriteria.isNotEmpty)
            _Section(
              title: l10n.deckPanelCriteria,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in ticket.acceptanceCriteria)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(item.done ? AppIcons.checkboxOn : AppIcons.checkboxOff, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(item.text)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          _Section(
            title: l10n.deckPanelProgress,
            child: percent == null && ticket.progress.note.isEmpty
                ? Text(l10n.deckPanelNoProgress)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (percent != null) ...[
                        Text('$percent%'),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(value: (percent / 100).clamp(0.0, 1.0)),
                        const SizedBox(height: 8),
                      ],
                      if (ticket.progress.note.isNotEmpty) Text(ticket.progress.note),
                    ],
                  ),
          ),
          // Unknown blockers (the tracker did not say) show no section at all.
          if (ticket.blockedBy case final blockers?)
            _Section(
              title: l10n.deckPanelBlockers,
              child: blockers.isEmpty
                  ? Text(l10n.deckPanelNoBlockers)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final b in blockers)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              [
                                _shortKey(b.key),
                                if (b.title case final t? when t.isNotEmpty) t,
                                if (b.state != null) '(${_stateLabel(context, closed: b.isClosed)})',
                              ].join(' '),
                            ),
                          ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text(title, style: groupTitleStyle(context))),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}
