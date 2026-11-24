// The deck's read-only panel over the relay tunnel: the feature is negotiated
// in `harness.transport.describe`, and only its two reads cross the allow-list.

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 3), retryCaps: [Duration(milliseconds: 30)]);

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late RemoteAccount account;

  setUp(() async {
    server = await FakeRemoteServer.start();
    host = await FakeRemoteHost.start(server);
    account = RemoteAccount(secrets: MemorySecretStore(), serverUrl: server.url);
  });

  tearDown(() async {
    await account.close();
    await host.close();
    await server.close();
  });

  Future<DshClient> connect() async {
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final client = await account.connectHost((await account.listHosts()).single, muxOptions: fastMux);
    await client.listSessions();
    return client;
  }

  test('a Host that announces deck.panel.read.v1 has the panel and serves both reads', () async {
    host.capabilities.add(deckPanelReadFeature);
    final calls = <(String, Map<String, Object?>)>[];
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
    // One Host method carries both reads; the `operation` field selects which
    // one. It is the Host's own RPC method, not a Gateway endpoint.
    host.hostMethods[deckPanelReadEndpoint] = (args) {
      calls.add(('${args['operation']}', args));
      return args['operation'] == deckTreeOperation
          ? {'ok': true, 'sessionId': 's1', 'containers': <Object?>[], 'truncated': false}
          : {
              'ok': true,
              'sessionId': 's1',
              'ticket': {'key': '84', 'title': 'Panel', 'state': 'OPEN', 'body': ''},
            };
    };
    final client = await connect();

    expect(client.supportsDeckPanel, isTrue);
    expect((await client.readDeckTree('s1')).containers, isEmpty);
    expect((await client.readDeckTicket('s1', '84')).title, 'Panel');
    expect(calls.map((c) => c.$1), [deckTreeOperation, deckTicketOperation]);
    expect(calls[0].$2, containsPair('sessionId', 's1'));
    expect(calls[1].$2, containsPair('key', '84'));
    expect(calls.expand((c) => c.$2.keys).toSet(), {'operation', 'sessionId', 'key'}, reason: 'never a path or a directory');
    expect(host.rpcMethods, contains(deckPanelReadEndpoint), reason: 'called as a Host method');
    expect(host.calls.map((c) => c.$1), isNot(contains(deckPanelReadEndpoint)), reason: 'not through the Gateway');
  });

  test('a Host that does not announce it has no panel, so the App never asks', () async {
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
    final client = await connect();
    expect(client.supportsDeckPanel, isFalse);
  });

  test('the allow-list carries the one deck read method and no other deck endpoint', () async {
    host.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
    final carrier = (await connect()).carrier;
    expect(carrier.allowsEndpoint(deckPanelReadEndpoint), isTrue);
    for (final other in [
      'deck.panel.read.comment',
      'deck.panel.write',
      'deckPanel/tree',
      'deckPanel/ticket',
      'deckPanel/close',
      'deck.panel',
    ]) {
      expect(carrier.allowsEndpoint(other), isFalse, reason: other);
    }
  });
}
