import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/search_capsule.dart';
import 'deck_tree_filter.dart';

class DeckTreeToolbar extends StatelessWidget {
  const DeckTreeToolbar({
    super.key,
    required this.search,
    required this.onSearchChanged,
    required this.status,
    required this.onStatusChanged,
    required this.order,
    required this.onOrderChanged,
  });

  final TextEditingController search;
  final ValueChanged<String> onSearchChanged;
  final DeckTreeStatus status;
  final ValueChanged<DeckTreeStatus> onStatusChanged;
  final DeckTreeOrder order;
  final ValueChanged<DeckTreeOrder> onOrderChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final statuses = {
      DeckTreeStatus.all: l10n.deckPanelFilterAll,
      DeckTreeStatus.open: l10n.deckPanelStateOpen,
      DeckTreeStatus.closed: l10n.deckPanelStateClosed,
      DeckTreeStatus.blocked: l10n.deckPanelFilterBlocked,
      DeckTreeStatus.ready: l10n.deckPanelFilterReady,
    };
    final orders = {
      DeckTreeOrder.host: l10n.deckPanelOrderHost,
      DeckTreeOrder.title: l10n.deckPanelOrderTitle,
      DeckTreeOrder.key: l10n.deckPanelOrderKey,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SearchCapsule(
            controller: search,
            hint: l10n.deckPanelSearch,
            onChanged: onSearchChanged,
            onClear: () {
              search.clear();
              onSearchChanged('');
            },
          ),
          Wrap(
            spacing: 8,
            children: [
              PopupMenuButton<DeckTreeStatus>(
                tooltip: l10n.deckPanelFilter,
                onSelected: onStatusChanged,
                itemBuilder: (_) => [
                  for (final entry in statuses.entries)
                    CheckedPopupMenuItem(value: entry.key, checked: entry.key == status, child: Text(entry.value)),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(l10n.deckPanelFilterValue(statuses[status]!)),
                ),
              ),
              PopupMenuButton<DeckTreeOrder>(
                tooltip: l10n.deckPanelOrder,
                onSelected: onOrderChanged,
                itemBuilder: (_) => [
                  for (final entry in orders.entries)
                    CheckedPopupMenuItem(value: entry.key, checked: entry.key == order, child: Text(entry.value)),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(l10n.deckPanelOrderValue(orders[order]!)),
                ),
              ),
            ],
          ),
          Text(l10n.deckPanelLoadedOnly, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
