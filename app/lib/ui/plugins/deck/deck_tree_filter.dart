import 'package:dsh_client/dsh_client.dart';

enum DeckTreeStatus { all, open, closed, blocked, ready }

enum DeckTreeOrder { host, title, key }

/// Selects from one loaded projection, without altering the source tree or
/// treating a missing standalone list as an empty one.
({List<({DeckContainer container, List<DeckTreeTicket> tickets})> groups, List<DeckTreeTicket>? standalone})
filterDeckTree(DeckTree tree, {required String query, required DeckTreeStatus status, required DeckTreeOrder order}) {
  final term = query.trim().toLowerCase();
  bool matches(String key, String title) =>
      term.isEmpty || deckDisplayKey(key).toLowerCase().contains(term) || title.toLowerCase().contains(term);

  List<DeckTreeTicket> select(List<DeckTreeTicket> tickets) {
    final selected = [
      for (final ticket in tickets)
        if (_matchesStatus(ticket, status) && matches(ticket.key, ticket.title)) ticket,
    ];
    if (order != DeckTreeOrder.host) {
      selected.sort((a, b) => _compare(order, a.key, a.title, b.key, b.title));
    }
    return selected;
  }

  final groups = <({DeckContainer container, List<DeckTreeTicket> tickets})>[];
  for (final container in tree.containers) {
    final tickets = select(container.tickets);
    // Status filters are for ticket rows. Keep each matching row under its
    // parent; with no status filter, containers can also match in their own right.
    if (tickets.isNotEmpty || (status == DeckTreeStatus.all && matches(container.key, container.title))) {
      groups.add((container: container, tickets: tickets));
    }
  }
  if (order != DeckTreeOrder.host) {
    groups.sort((a, b) => _compare(order, a.container.key, a.container.title, b.container.key, b.container.title));
  }
  final standalone = tree.standaloneIssues;
  return (groups: groups, standalone: standalone == null ? null : select(standalone));
}

bool _matchesStatus(DeckTreeTicket ticket, DeckTreeStatus status) => switch (status) {
  DeckTreeStatus.all => true,
  DeckTreeStatus.open => ticket.state == 'OPEN',
  DeckTreeStatus.closed => ticket.isClosed,
  DeckTreeStatus.blocked => ticket.state == 'OPEN' && ticket.openBlockers.isNotEmpty,
  DeckTreeStatus.ready => ticket.state == 'OPEN' && ticket.isFree,
};

final _numericKey = RegExp(r'^\d+$');

/// `84` reads as `#84`; a key like `OMB-923` is already what people say.
String deckDisplayKey(String key) => _numericKey.hasMatch(key) ? '#$key' : key;

int _compare(DeckTreeOrder order, String keyA, String titleA, String keyB, String titleB) {
  if (order == DeckTreeOrder.title) {
    final titleOrder = titleA.toLowerCase().compareTo(titleB.toLowerCase());
    if (titleOrder != 0) return titleOrder;
  }
  final numberA = _numericKey.hasMatch(keyA) ? int.tryParse(keyA) : null;
  final numberB = _numericKey.hasMatch(keyB) ? int.tryParse(keyB) : null;
  if (numberA != null && numberB != null) {
    final numberOrder = numberA.compareTo(numberB);
    if (numberOrder != 0) return numberOrder;
  } else if (numberA != null || numberB != null) {
    return numberA != null ? -1 : 1;
  }
  final keyOrder = keyA.toLowerCase().compareTo(keyB.toLowerCase());
  return keyOrder == 0 ? keyA.compareTo(keyB) : keyOrder;
}
