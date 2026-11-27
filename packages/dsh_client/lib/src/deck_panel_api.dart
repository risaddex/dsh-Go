/// The read-only deck panel's channel (`deck.panel.read.v1`): two reads,
/// `tree` and `ticket`, both scoped by a conversation's `sessionId`.
///
/// The App never sends a working directory or a path: the Host resolves the
/// workspace from the session. The feature exists only when the connected
/// Host announced it during the Remote capability negotiation
/// ([DshCarrier.peerCapabilities]); a Host that did not, or a carrier with no
/// such negotiation (local and SSH HTTP hosts), has no deck panel at all, so
/// nothing probes a route that is not there.
///
/// A Host failure comes back as the deck's `{ok: false, error: {kind}}` and
/// is raised as [DshRemoteException] with that `kind` as its code. A reply
/// that is malformed, is for another session, or is larger than the deck's own
/// byte bound is a [DshProtocolException]: nothing partial is ever returned.
library;

import 'dart:convert';

import 'carrier.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

/// The feature name the Host announces.
const deckPanelReadFeature = 'deck.panel.read.v1';

/// The one RPC method that carries both deck reads on the Host, and the value
/// of its `operation` field that selects each of them. This is the contract
/// ds-harness-remote (#83) implements and documents (its
/// `docs/protocol.md`, section "Read-only deck panel"): a single method with
/// `{operation: 'tree', sessionId}` or `{operation: 'ticket', sessionId, key}`.
/// Do not split it into one endpoint per read again: a Host that only knows
/// this method answers `METHOD_NOT_ALLOWED` to any other name, which is how the
/// first real-device run of #75 found the mismatch.
const deckPanelReadEndpoint = 'deck.panel.read';
const deckTreeOperation = 'tree';
const deckTicketOperation = 'ticket';

/// The deck's own bound for one whole reply (`DECK_READ_LIMITS.maxProjectionBytes`).
const deckReplyMaxBytes = 262144;

/// A blocker of a ticket; [state] is `OPEN` / `CLOSED` when the Host knew it.
final class DeckBlocker {
  const DeckBlocker({required this.key, this.title, this.state});

  final String key;
  final String? title;
  final String? state;

  bool get isClosed => state == 'CLOSED';

  static DeckBlocker? _from(Object? json) {
    final map = asMap(json);
    final key = map?['key'];
    if (map == null || (key is! String && key is! num)) return null;
    return DeckBlocker(key: '$key', title: asString(map['title']), state: asString(map['state']));
  }
}

/// A ticket row inside a tree container.
final class DeckTreeTicket {
  const DeckTreeTicket({
    required this.key,
    required this.number,
    required this.title,
    required this.state,
    required this.url,
    this.blockedBy,
  });

  final String key;
  final int? number;
  final String title;

  /// `OPEN` or `CLOSED`.
  final String state;
  final String url;

  /// Null when the tracker did not say (unknown); empty when it said none.
  final List<DeckBlocker>? blockedBy;

  bool get isClosed => state == 'CLOSED';

  /// The blockers still in the way (a blocker whose state is unknown is).
  List<DeckBlocker> get openBlockers => [
    for (final b in blockedBy ?? const <DeckBlocker>[])
      if (!b.isClosed) b,
  ];

  /// Free to pick up: open, its blockers known, and none of them in the way.
  /// An unknown blocker list is never "free": claiming a ticket is free when it
  /// is not is the worse mistake. "Free" here means unblocked only: the deck's
  /// tree rows carry no assignee, so a ticket someone already claimed still
  /// reads free.
  bool get isFree => !isClosed && blockedBy != null && openBlockers.isEmpty;
}

enum DeckContainerKind { map, spec }

/// An open map or spec with its child tickets.
final class DeckContainer {
  const DeckContainer({
    required this.key,
    required this.number,
    required this.kind,
    required this.title,
    required this.state,
    required this.url,
    required this.tickets,
  });

  final String key;
  final int? number;
  final DeckContainerKind kind;
  final String title;
  final String state;
  final String url;

  /// Empty when the tracker did not list children.
  final List<DeckTreeTicket> tickets;
}

/// The `tree` reply: open maps and specs, cut at 50 containers / 200 tickets.
final class DeckTree {
  const DeckTree({
    required this.sessionId,
    required this.containers,
    required this.truncated,
    required this.omittedContainers,
    required this.omittedTickets,
    this.standaloneIssues,
  });

  final String sessionId;
  final List<DeckContainer> containers;

  /// Null on older hosts; an empty list confirms there are no standalone rows
  /// in this projection (subject to [truncated]).
  final List<DeckTreeTicket>? standaloneIssues;

  /// Something was left out (the tracker's own listing, or a limit).
  final bool truncated;
  final int omittedContainers;
  final int omittedTickets;
}

final class DeckLabel {
  const DeckLabel({required this.name, required this.color});
  final String name;
  final String color;
}

final class DeckAcceptanceItem {
  const DeckAcceptanceItem({required this.text, required this.done});
  final String text;
  final bool done;
}

/// Structured progress; [percent] is null when none was written (not 0).
final class DeckProgress {
  const DeckProgress({required this.percent, required this.note, required this.updatedAt});
  final int? percent;
  final String note;
  final String? updatedAt;
}

/// A proposed composer draft, never an instruction to send or run directly.
final class DeckTicketAction {
  const DeckTicketAction({required this.id, required this.label, required this.prompt});

  final String id;
  final String label;
  final String prompt;
}

/// The `ticket` reply: read-only fields and optional composer drafts.
final class DeckTicketDetail {
  const DeckTicketDetail({
    required this.key,
    required this.number,
    required this.title,
    required this.state,
    required this.url,
    required this.labels,
    required this.body,
    required this.acceptanceCriteria,
    required this.progress,
    required this.blockedBy,
    this.actions = const [],
  });

  final String key;
  final int? number;
  final String title;
  final String state;
  final String url;
  final List<DeckLabel> labels;
  final String body;
  final List<DeckAcceptanceItem> acceptanceCriteria;
  final DeckProgress progress;
  final List<DeckTicketAction> actions;

  /// Null when the tracker did not say; empty when it said none.
  final List<DeckBlocker>? blockedBy;

  bool get isClosed => state == 'CLOSED';
}

DshProtocolException _protocolError(String what) => DshProtocolException('deck panel reply: $what');

String _text(JsonMap map, String key) => asString(map[key]) ?? '';

String _required(JsonMap map, String key) {
  final value = asString(map[key]);
  if (value == null || value.trim().isEmpty) throw _protocolError('missing $key');
  return value;
}

/// An unreadable blocker fails the whole reply: dropping it would make a
/// blocked ticket look free.
List<DeckBlocker>? _blockers(Object? json) =>
    json is List ? [for (final b in json) DeckBlocker._from(b) ?? (throw _protocolError('unreadable blocker'))] : null;

DeckTreeTicket _treeTicket(Object? json) {
  final map = asMap(json) ?? (throw _protocolError('ticket row is not an object'));
  return DeckTreeTicket(
    key: _required(map, 'key'),
    number: asInt(map['number']),
    title: _text(map, 'title'),
    state: _text(map, 'state'),
    url: _text(map, 'url'),
    blockedBy: _blockers(map['blockedBy']),
  );
}

DeckContainer _container(Object? json) {
  final map = asMap(json) ?? (throw _protocolError('container is not an object'));
  final kind = switch (map['kind']) {
    'map' => DeckContainerKind.map,
    'spec' => DeckContainerKind.spec,
    _ => throw _protocolError('unknown container kind'),
  };
  return DeckContainer(
    key: _required(map, 'key'),
    number: asInt(map['number']),
    kind: kind,
    title: _text(map, 'title'),
    state: _text(map, 'state'),
    url: _text(map, 'url'),
    tickets: [for (final t in asListOrEmpty(map['tickets'])) _treeTicket(t)],
  );
}

List<DeckTicketAction> _ticketActions(Object? json) {
  if (json is! List || json.length > 8) return const [];
  return [
    for (final item in json)
      if (asMap(item) case final entry?)
        if ((_text(entry, 'id'), _text(entry, 'label'), _text(entry, 'prompt'))
            case (final id, final label, final prompt)
            when id.isNotEmpty &&
                id.length <= 64 &&
                label.trim().isNotEmpty &&
                label.length <= 128 &&
                prompt.trim().isNotEmpty &&
                utf8.encode(prompt).length <= 24576)
          DeckTicketAction(id: id, label: label, prompt: prompt),
  ];
}

DeckTicketDetail _detail(Object? json) {
  final map = asMap(json) ?? (throw _protocolError('ticket is not an object'));
  final progress = asMapOrEmpty(map['progress']);
  return DeckTicketDetail(
    key: _required(map, 'key'),
    number: asInt(map['number']),
    title: _text(map, 'title'),
    state: _text(map, 'state'),
    url: _text(map, 'url'),
    labels: [
      for (final l in asListOrEmpty(map['labels']))
        if (asMap(l) case final label? when _text(label, 'name').isNotEmpty)
          DeckLabel(name: _text(label, 'name'), color: _text(label, 'color')),
    ],
    body: _text(map, 'body'),
    acceptanceCriteria: [
      for (final a in asListOrEmpty(map['acceptanceCriteria']))
        if (asMap(a) case final item?)
          DeckAcceptanceItem(text: _text(item, 'text'), done: asBool(item['done']) ?? false),
    ],
    progress: DeckProgress(
      percent: asInt(progress['percent']),
      note: _text(progress, 'note'),
      updatedAt: asString(progress['updatedAt']),
    ),
    blockedBy: _blockers(map['blockedBy']),
    actions: _ticketActions(map['actions']),
  );
}

extension DeckPanelApi on DshClient {
  /// Whether the connected Host announced `deck.panel.read.v1`. No
  /// announcement (including a carrier with no negotiation) means no panel.
  bool get supportsDeckPanel => carrier.peerCapabilities?.contains(deckPanelReadFeature) ?? false;

  /// `tree`: the open maps and specs of [sessionId]'s workspace.
  Future<DeckTree> readDeckTree(String sessionId) async {
    final reply = await _deckRead({'operation': deckTreeOperation, 'sessionId': sessionId}, sessionId);
    final containers = reply['containers'];
    if (containers is! List) throw _protocolError('missing containers');
    final standalone = reply['standaloneIssues'];
    if (reply.containsKey('standaloneIssues') && standalone is! List) {
      throw _protocolError('standaloneIssues is not a list');
    }
    final parsedContainers = [for (final c in containers) _container(c)];
    final standaloneIssues = standalone is List ? [for (final t in standalone) _treeTicket(t)] : null;
    if (standaloneIssues != null &&
        parsedContainers.fold(standaloneIssues.length, (count, c) => count + c.tickets.length) > 200) {
      throw _protocolError('over 200 tickets');
    }
    return DeckTree(
      sessionId: sessionId,
      containers: parsedContainers,
      standaloneIssues: standaloneIssues,
      truncated: reply['truncated'] == true,
      omittedContainers: asInt(reply['omittedContainers']) ?? 0,
      omittedTickets: asInt(reply['omittedTickets']) ?? 0,
    );
  }

  /// `ticket`: one ticket's detail by its tracker [key].
  Future<DeckTicketDetail> readDeckTicket(String sessionId, String key) async {
    final reply = await _deckRead({'operation': deckTicketOperation, 'sessionId': sessionId, 'key': key}, sessionId);
    final ticket = _detail(reply['ticket']);
    if (ticket.key != key) throw _protocolError('another ticket');
    return ticket;
  }

  Future<JsonMap> _deckRead(Map<String, Object?> args, String sessionId) async {
    final reply = asMap(await rpc.call(deckPanelReadEndpoint, args)) ?? (throw _protocolError('not an object'));
    // The ticket asks for an oversized reply to be a failure, and a relay in
    // between may not have bounded it: measure what actually arrived.
    if (utf8.encode(jsonEncode(reply)).length > deckReplyMaxBytes)
      throw _protocolError('over $deckReplyMaxBytes bytes');
    if (reply['ok'] == false) {
      final error = asMapOrEmpty(reply['error']);
      throw DshRemoteException(
        asString(error['kind']) ?? 'read-failed',
        asString(error['message']) ?? 'The deck read failed',
      );
    }
    if (reply['ok'] != true) throw _protocolError('no ok flag');
    if (reply['sessionId'] != sessionId) throw _protocolError('another session');
    return reply;
  }
}
