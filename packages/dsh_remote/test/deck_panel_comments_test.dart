import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late RemoteAccount account;

  setUp(() async {
    server = await FakeRemoteServer.start();
    host = await FakeRemoteHost.start(server);
    account = RemoteAccount(secrets: MemorySecretStore(), serverUrl: server.url);
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
  });

  tearDown(() async {
    await account.close();
    await host.close();
    await server.close();
  });

  Future<DshClient> connect() async {
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final client = await account.connectHost((await account.listHosts()).single);
    await client.listSessions();
    return client;
  }

  test('comments capability alone routes exact page reads directly to the Host', () async {
    host.capabilities.add(deckPanelCommentsFeature);
    final calls = <Map<String, Object?>>[];
    host.hostMethods[deckPanelCommentsEndpoint] = (args) {
      calls.add(args);
      return {
        'ok': true,
        'sessionId': args['sessionId'],
        'key': args['key'],
        'comments': [
          {'body': 'Comment ${calls.length}', 'author': 'Maintainer', 'createdAt': '2026-11-26T12:00:00Z'},
        ],
        if (calls.length == 1) 'nextCursor': 'opaque_cursor',
        if (calls.length == 2) 'truncated': true,
      };
    };
    final client = await connect();
    expect(client.supportsDeckPanelComments, isTrue);
    expect(client.supportsDeckPanel, isFalse);
    final first = await client.readDeckComments('s1', 'ABC-7');
    expect(first.comments.single.body, 'Comment 1');
    expect(first.comments.single.author, 'Maintainer');
    expect(first.comments.single.createdAt, '2026-11-26T12:00:00Z');
    expect(first.comments.single.updatedAt, isNull);
    final last = await client.readDeckComments('s1', 'ABC-7', cursor: first.nextCursor);
    expect(last.comments.single.body, 'Comment 2');
    expect(last.nextCursor, isNull);
    expect(last.truncated, isTrue);
    expect(calls, [
      {'sessionId': 's1', 'key': 'ABC-7'},
      {'sessionId': 's1', 'key': 'ABC-7', 'cursor': 'opaque_cursor'},
    ]);
    expect(host.rpcMethods.where((m) => m == deckPanelCommentsEndpoint), hasLength(2));
    expect(host.calls.map((c) => c.$1), isNot(contains(deckPanelCommentsEndpoint)));
    expect(client.carrier.allowsEndpoint('deck.panel.comments.create'), isFalse);
  });

  test('base panel capability does not probe for comments', () async {
    host.capabilities.add(deckPanelReadFeature);
    final client = await connect();
    expect(client.supportsDeckPanel, isTrue);
    expect(client.supportsDeckPanelComments, isFalse);
    await expectLater(client.readDeckComments('s1', 'ABC-7'), throwsA(isA<DshRemoteException>()));
    expect(host.rpcMethods, isNot(contains(deckPanelCommentsEndpoint)));
  });

  test('rejects mismatched echoes, malformed comments and oversized pages', () async {
    host.capabilities.add(deckPanelCommentsFeature);
    final client = await connect();
    for (final fields in <Map<String, Object?>>[
      {'sessionId': 's2'},
      {'key': 'abc-7'},
      {'key': 7},
      {
        'comments': List.filled(51, {'body': 'comment'}),
      },
      {
        'comments': <Object?>[
          {'body': false},
        ],
      },
      {'nextCursor': ''},
      {'truncated': 'true'},
    ]) {
      host.hostMethods[deckPanelCommentsEndpoint] = (_) => {
        'ok': true,
        'sessionId': 's1',
        'key': 'ABC-7',
        'comments': [],
        ...fields,
      };
      await expectLater(client.readDeckComments('s1', 'ABC-7'), throwsA(isA<DshProtocolException>()));
    }
    host.hostMethods[deckPanelCommentsEndpoint] = (_) => {
      'ok': false,
      'error': {'kind': 'not-found', 'message': 'Ticket not found'},
    };
    await expectLater(
      client.readDeckComments('s1', 'ABC-7'),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'not-found')),
    );
  });
}
