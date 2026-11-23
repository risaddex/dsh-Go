// The deck's read-only panel (spec #70, deck.panel.read.v1) in 对话详情's
// 「插件」 tab: the open maps and specs of the conversation's workspace with
// their tickets, and one ticket's detail on demand.
//
// What it reads, and when: the tree once when it opens and again only when
// the person taps Refresh; one ticket each time one is opened. What it read
// lives in this widget's state alone: no cache between interactions, no timer,
// no polling. Going back from a ticket shows the tree already read. There is
// no write, comment or prompt control anywhere on it.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/deck/deck_panel_state.dart';
import '../../common/app_sheet.dart' show groupTitleStyle;
import '../../common/empty_view.dart';
import '../../common/list_page_row.dart';
import '../../common/status_chip.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

class DeckPanelView extends ConsumerStatefulWidget {
  const DeckPanelView({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<DeckPanelView> createState() => _DeckPanelViewState();
}

class _DeckPanelViewState extends ConsumerState<DeckPanelView> {
  AsyncValue<DeckTree> _tree = const AsyncLoading();

  /// The ticket whose detail is showing; null shows the tree.
  String? _open;
  AsyncValue<DeckTicketDetail> _ticket = const AsyncLoading();

  /// Which read a reply belongs to: a reply that is not the latest one of its
  /// kind (a refresh, another ticket, Back in the meantime) is dropped.
  int _treeRun = 0;
  int _ticketRun = 0;

  @override
  void initState() {
    super.initState();
    _startTree();
  }

  @override
  void didUpdateWidget(DeckPanelView old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) {
      _open = null;
      _ticketRun++;
      _startTree();
    }
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
    if (mounted && run == _treeRun) setState(() => _tree = result);
  }

  void _openTicket(String key) {
    final run = ++_ticketRun;
    setState(() {
      _open = key;
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
    if (mounted && run == _ticketRun) setState(() => _ticket = result);
  }

  void _back() => setState(() {
    _open = null;
    _ticketRun++;
  });

  @override
  Widget build(BuildContext context) {
    if (ref.watch(deckPanelReaderProvider) == null) return const SizedBox.shrink();
    final open = _open;
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
        data: (tree) => _TreeBody(tree: tree, onOpen: _openTicket),
      ),
    ];
  }

  List<Widget> _detailChildren(BuildContext context, String key) {
    final l10n = context.l10n;
    return [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: _back,
          icon: const Icon(AppIcons.back),
          label: Text(l10n.deckPanelBack),
        ),
      ),
      _ticket.when(
        loading: () => const _Loading(),
        // A ticket failure stays here: the tree behind it is kept.
        error: (_, _) => EmptyView(
          icon: AppIcons.error,
          title: l10n.deckPanelTicketError,
          actionLabel: l10n.deckPanelRetry,
          onAction: () => _openTicket(key),
        ),
        data: (ticket) => _TicketBody(ticket: ticket),
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

/// `84` reads as `#84`; a key like `OMB-923` is already what people say.
String _shortKey(String key) => RegExp(r'^\d+$').hasMatch(key) ? '#$key' : key;

String _stateLabel(BuildContext context, String state) =>
    state == 'CLOSED' ? context.l10n.deckPanelStateClosed : context.l10n.deckPanelStateOpen;

class _TreeBody extends StatelessWidget {
  const _TreeBody({required this.tree, required this.onOpen});

  final DeckTree tree;
  final void Function(String key) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (tree.containers.isEmpty) {
      return EmptyView(icon: AppIcons.todo, title: l10n.deckPanelEmpty, compact: true);
    }
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
        for (final container in tree.containers) ...[
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
                    child: Text(
                      '${_shortKey(container.key)} ${container.title}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (container.tickets.isNotEmpty)
            ListPageCard(
              children: [for (final ticket in container.tickets) _TicketRow(ticket: ticket, onOpen: onOpen)],
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
    final blocking = [
      for (final b in ticket.blockedBy ?? const <DeckBlocker>[])
        if (!b.isClosed) _shortKey(b.key),
    ];
    final String? note = ticket.isFree
        ? l10n.deckPanelFree
        : (ticket.state != 'CLOSED' && blocking.isNotEmpty ? l10n.deckPanelBlockedBy(blocking.join(', ')) : null);
    return ListPageRow(
      title: '${_shortKey(ticket.key)} ${ticket.title}',
      titleMaxLines: 2,
      subtitle: note,
      subtitleMaxLines: 2,
      subtitleColor: ticket.isFree ? DshColors.of(context).success : null,
      meta: _stateLabel(context, ticket.state),
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
    final status = ticket.status;
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
                tone: ticket.state == 'CLOSED' ? StatusTone.idle : StatusTone.ok,
                label: _stateLabel(context, ticket.state),
              ),
              if (status != null && status.isNotEmpty) StatusChip(tone: StatusTone.idle, label: status),
            ],
          ),
          if (ticket.labels.isNotEmpty)
            _Section(
              title: l10n.deckPanelLabels,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final label in ticket.labels) StatusChip(tone: StatusTone.idle, label: label.name)],
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
                                if (b.state case final s?) '(${_stateLabel(context, s)})',
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
