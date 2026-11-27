import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';

typedef DeckCommentsReader = Future<DeckCommentsPage> Function(String sessionId, String key, {String? cursor});

/// The comments capability stands on its own. Read the current handshake
/// again on reconnect even if the connection reuses its DshClient.
final deckPanelCommentsReaderProvider = Provider.autoDispose<DeckCommentsReader?>((ref) {
  final host = ref.watch(activeHostProvider);
  final connected = ref.watch(hostLinkStatusProvider(host).select((s) => s.value?.isConnected ?? false));
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  return connected && client != null && client.supportsDeckPanelComments ? client.readDeckComments : null;
});
