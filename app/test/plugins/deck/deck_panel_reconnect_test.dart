// deck.panel.read.v1 is negotiated again on a reconnect: the link keeps its
// client but the Host answers the feature negotiation anew, so a Host that
// stopped announcing the deck (its plugin was turned off) must lose the panel.
// Split from deck_panel_test.dart, which is at the size limit.

import 'dart:async';

import 'package:dsh_app/plugins/deck/deck_panel_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A carrier that only reports the features its Host announces, read live.
class _Carrier extends DshCarrier {
  _Carrier(this.capabilities);

  final Set<String> capabilities;

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

void main() {
  test('a reconnect that negotiates again drops the panel when the Host stopped announcing it', () async {
    final capabilities = <String>{deckPanelReadFeature};
    final client = DshClient.withCarrier(_Carrier(capabilities));
    addTearDown(client.close);
    final statuses = StreamController<HostLinkStatus>();
    addTearDown(statuses.close);
    final c = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(client: client, label: 'relay', isLocal: false)),
        ),
        hostLinkStatusProvider(HostRef.local).overrideWith((ref) => statuses.stream),
      ],
    );
    addTearDown(c.dispose);
    c.listen(deckPanelReaderProvider, (_, _) {});
    c.listen(hostLinkStatusProvider(HostRef.local), (_, _) {});
    const connected = HostLinkStatus(HostLinkPhase.connected);
    statuses.add(connected);
    await pumpEventQueue();
    expect(c.read(deckPanelReaderProvider), isNotNull);

    // The link drops and comes back; on the way the Host's answer changed.
    statuses.add(const HostLinkStatus(HostLinkPhase.reconnecting, attempt: 1));
    await pumpEventQueue();
    expect(c.read(deckPanelReaderProvider), isNotNull, reason: 'a link that is down keeps what it knew');
    capabilities.remove(deckPanelReadFeature);
    statuses.add(connected);
    await pumpEventQueue();
    expect(c.read(deckPanelReaderProvider), isNull);
  });
}
