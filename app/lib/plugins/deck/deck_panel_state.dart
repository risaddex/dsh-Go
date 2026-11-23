// The read-only deck panel's reader (spec #70, deck.panel.read.v1): the one
// door from the panel to the connected Host's deck channel.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';

/// The two reads of the deck channel, scoped by a conversation's session id
/// (never a path). The panel keeps what it read in its own state: there is no
/// cache behind this.
abstract interface class DeckPanelReader {
  Future<DeckTree> tree(String sessionId);

  Future<DeckTicketDetail> ticket(String sessionId, String key);
}

/// [DeckPanelReader] over a connected [DshClient].
class ClientDeckPanelReader implements DeckPanelReader {
  const ClientDeckPanelReader(this.client);

  final DshClient client;

  @override
  Future<DeckTree> tree(String sessionId) => client.readDeckTree(sessionId);

  @override
  Future<DeckTicketDetail> ticket(String sessionId, String key) => client.readDeckTicket(sessionId, key);
}

/// The active host's deck reader, only while that host announced
/// `deck.panel.read.v1`; null otherwise (local and SSH hosts, relay hosts
/// with an older deck or Remote plugin). Null is the whole answer: the panel
/// does not exist then, and nothing is probed.
///
/// The announcement is read again every time the link comes back to connected
/// after having been down: a reconnect keeps the same client but negotiates
/// again, and the Host may have stopped announcing the feature meanwhile (the
/// deck plugin was turned off). This is a read of what the link already
/// negotiated, not a probe of the deck, and it has no timer.
final deckPanelReaderProvider = Provider<DeckPanelReader?>((ref) {
  final host = ref.watch(activeHostProvider);
  ref.listen(hostLinkStatusProvider(host), (previous, next) {
    // `previous.value` is null until the first status arrives; that first
    // arrival is the connection this build already read, not a reconnect.
    final wasConnected = previous?.value?.isConnected;
    if (wasConnected == false && (next.value?.isConnected ?? false)) ref.invalidateSelf();
  });
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null || !client.supportsDeckPanel) return null;
  return ClientDeckPanelReader(client);
});
