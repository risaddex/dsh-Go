// The read-only deck panel channel (deck.panel.read.v1): negotiation, the
// two reads and their fail-closed handling, against a fake carrier that
// records what is sent.

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

Map<String, Object?> treeReply({String sessionId = 's1', List<Object?>? containers, Map<String, Object?> extra = const {}}) => {
  'ok': true,
  'sessionId': sessionId,
  'containers':
      containers ??
      [
        {
          'key': '70',
          'number': 70,
          'kind': 'spec',
          'title': 'Deck over remote',
          'state': 'OPEN',
          'url': 'https://example.test/70',
          'tickets': [
            {
              'key': '83',
              'number': 83,
              'title': 'Forward',
              'state': 'OPEN',
              'url': '',
              'blockedBy': <Object?>[],
            },
            {
              'key': '84',
              'number': 84,
              'title': 'Panel',
              'state': 'OPEN',
              'url': '',
              'blockedBy': [
                {'key': '83', 'state': 'OPEN'},
              ],
            },
            {'key': '85', 'number': 85, 'title': 'Unknown', 'state': 'OPEN', 'url': ''},
          ],
        },
        {'key': '56', 'number': 56, 'kind': 'map', 'title': 'Map', 'state': 'OPEN', 'url': ''},
      ],
  'truncated': false,
  'omittedContainers': 0,
  'omittedTickets': 0,
  ...extra,
};

Map<String, Object?> ticketReply({String sessionId = 's1'}) => {
  'ok': true,
  'sessionId': sessionId,
  'ticket': {
    'key': '84',
    'number': 84,
    'title': 'Panel',
    'state': 'OPEN',
    'url': 'https://example.test/84',
    'labels': [
      {'name': 'ready-for-agent', 'color': 'ff0000'},
    ],
    'body': '## What\nBuild it',
    'acceptanceCriteria': [
      {'text': 'Shows tree', 'done': true},
      {'text': 'Shows ticket', 'done': false},
    ],
    'progress': {'percent': 40, 'note': 'half', 'updatedAt': '2026-11-24', 'entries': <Object?>[]},
    'blockedBy': [
      {'key': 83, 'title': 'Forward', 'state': 'OPEN'},
    ],
  },
};

void main() {
  late _FakeCarrier carrier;
  late DshClient client;

  DshClient connect({Set<String>? capabilities}) {
    carrier = _FakeCarrier(capabilities);
    client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    return client;
  }

  group('negotiation', () {
    test('only a Host that announced deck.panel.read.v1 has the panel', () {
      expect(connect(capabilities: {'harness.remote.v3', deckPanelReadFeature}).supportsDeckPanel, isTrue);
      expect(connect(capabilities: {'harness.remote.v3'}).supportsDeckPanel, isFalse);
    });

    test('a carrier with no negotiation (local and SSH HTTP hosts) has no panel', () {
      expect(connect().supportsDeckPanel, isFalse);
    });
  });

  group('tree', () {
    test('sends the session id only and reads maps and specs with their tickets', () async {
      connect(capabilities: {deckPanelReadFeature});
      carrier.replies[deckTreeEndpoint] = treeReply();
      final tree = await client.readDeckTree('s1');

      expect(carrier.sent.map((c) => c.$1), [deckTreeEndpoint]);
      expect(carrier.sent.single.$2, {'sessionId': 's1'}, reason: 'the session id and nothing else');
      expect(tree.containers.map((c) => (c.key, c.kind)), [('70', DeckContainerKind.spec), ('56', DeckContainerKind.map)]);
      final tickets = tree.containers.first.tickets;
      expect(tickets.map((t) => t.isFree), [true, false, false], reason: 'no blockers, an open blocker, unknown blockers');
      expect(tree.containers.last.tickets, isEmpty);
      expect(tree.truncated, isFalse);
    });

    test('a closed blocker does not hold a ticket back, a blocker with no state does', () async {
      connect(capabilities: {deckPanelReadFeature});
      carrier.replies[deckTreeEndpoint] = treeReply(
        containers: [
          {
            'key': '1',
            'kind': 'map',
            'title': 'm',
            'state': 'OPEN',
            'tickets': [
              {
                'key': '2',
                'title': 'a',
                'state': 'OPEN',
                'blockedBy': [
                  {'key': '9', 'state': 'CLOSED'},
                ],
              },
              {
                'key': '3',
                'title': 'b',
                'state': 'OPEN',
                'blockedBy': [
                  {'key': '9'},
                ],
              },
              {'key': '4', 'title': 'closed', 'state': 'CLOSED', 'blockedBy': <Object?>[]},
            ],
          },
        ],
      );
      final tickets = (await client.readDeckTree('s1')).containers.single.tickets;
      expect(tickets.map((t) => t.isFree), [true, false, false]);
    });

    test('carries the truncation signal and the omitted counts', () async {
      connect(capabilities: {deckPanelReadFeature});
      carrier.replies[deckTreeEndpoint] = treeReply(
        extra: {'truncated': true, 'omittedContainers': 3, 'omittedTickets': 17},
      );
      final tree = await client.readDeckTree('s1');
      expect((tree.truncated, tree.omittedContainers, tree.omittedTickets), (true, 3, 17));
    });

    test('an empty workspace is an empty tree, not a failure', () async {
      connect(capabilities: {deckPanelReadFeature});
      carrier.replies[deckTreeEndpoint] = treeReply(containers: <Object?>[]);
      expect((await client.readDeckTree('s1')).containers, isEmpty);
    });
  });

  group('ticket', () {
    test('sends the session id and the key only and reads the seven fields', () async {
      connect(capabilities: {deckPanelReadFeature});
      carrier.replies[deckTicketEndpoint] = ticketReply();
      final ticket = await client.readDeckTicket('s1', '84');

      expect(carrier.sent.map((c) => c.$1), [deckTicketEndpoint]);
      expect(carrier.sent.single.$2, {'sessionId': 's1', 'key': '84'}, reason: 'the session id and the key only');
      expect((ticket.title, ticket.state, ticket.isClosed), ('Panel', 'OPEN', false));
      expect(ticket.labels.single.name, 'ready-for-agent');
      expect(ticket.body, contains('Build it'));
      expect(ticket.acceptanceCriteria.map((a) => (a.text, a.done)), [('Shows tree', true), ('Shows ticket', false)]);
      expect((ticket.progress.percent, ticket.progress.note), (40, 'half'));
      expect(ticket.blockedBy!.single.key, '83', reason: 'a numeric blocker key is read as text');
    });
  });

  group('failures', () {
    setUp(() => connect(capabilities: {deckPanelReadFeature}));

    test("the deck's failure kind is the error code, and nothing else leaks", () async {
      carrier.replies[deckTreeEndpoint] = {
        'ok': false,
        'error': {'kind': 'timeout', 'message': 'The deck read did not finish in time'},
      };
      await expectLater(
        client.readDeckTree('s1'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'timeout')),
      );
    });

    test('a reply for another session is refused', () async {
      carrier.replies[deckTreeEndpoint] = treeReply(sessionId: 'other');
      await expectLater(client.readDeckTree('s1'), throwsA(isA<DshProtocolException>()));
    });

    test('malformed replies are refused, not repaired', () async {
      final bad = <Object?>[
        'text',
        {'ok': true, 'sessionId': 's1'},
        {'ok': true, 'sessionId': 's1', 'containers': 'nope'},
        treeReply(containers: [
          {'key': '1', 'kind': 'epic', 'title': 'x', 'state': 'OPEN'},
        ]),
        treeReply(containers: [
          {'kind': 'map', 'title': 'no key', 'state': 'OPEN'},
        ]),
        {'sessionId': 's1', 'containers': <Object?>[]},
      ];
      for (final reply in bad) {
        carrier.replies[deckTreeEndpoint] = reply;
        await expectLater(client.readDeckTree('s1'), throwsA(isA<DshProtocolException>()), reason: '$reply');
      }
      carrier.replies[deckTicketEndpoint] = {'ok': true, 'sessionId': 's1', 'ticket': 'x'};
      await expectLater(client.readDeckTicket('s1', '84'), throwsA(isA<DshProtocolException>()));
    });

    test('an unreadable blocker fails the reply instead of making a blocked ticket look free', () async {
      carrier.replies[deckTreeEndpoint] = treeReply(
        containers: [
          {
            'key': '1',
            'kind': 'map',
            'title': 'm',
            'state': 'OPEN',
            'tickets': [
              {
                'key': '2',
                'title': 'a',
                'state': 'OPEN',
                'blockedBy': [
                  {'title': 'no key'},
                ],
              },
            ],
          },
        ],
      );
      await expectLater(client.readDeckTree('s1'), throwsA(isA<DshProtocolException>()));
    });

    test('a reply over the deck byte bound is refused', () async {
      carrier.replies[deckTicketEndpoint] = {
        ...ticketReply(),
        'padding': 'x' * deckReplyMaxBytes,
      };
      await expectLater(client.readDeckTicket('s1', '84'), throwsA(isA<DshProtocolException>()));
    });

    test('a carrier failure propagates', () async {
      carrier.fail = const DshTransportException('down');
      await expectLater(client.readDeckTree('s1'), throwsA(isA<DshTransportException>()));
    });
  });
}

/// A tunnel-like carrier: a fixed answer per endpoint, a record of every call.
class _FakeCarrier extends DshCarrier {
  _FakeCarrier(this.capabilities);

  final Set<String>? capabilities;
  final Map<String, Object?> replies = {};
  final List<(String, Map<String, Object?>)> sent = [];
  DshException? fail;

  @override
  Set<String>? get peerCapabilities => capabilities;

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    sent.add((endpoint, args));
    if (fail != null) throw fail!;
    return RpcOk(replies[endpoint]);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw const DshTransportException('no link');

  @override
  Future<void> close() async {}
}