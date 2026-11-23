// The read-only deck panel's reader (spec #70, deck.panel.read.v1): the one
// door from the panel to the connected Host's deck channel.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';

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
final deckPanelReaderProvider = Provider<DeckPanelReader?>((ref) {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null || !client.supportsDeckPanel) return null;
  return ClientDeckPanelReader(client);
});
