// `deck-panel`: the deck's read-only panel (spec #70) in 对话详情's 「插件」
// tab. Its one occupant exists only while the connected host announced
// `deck.panel.read.v1` (SeatInventory.deckPanel), so a host that did not has
// no entry, no empty page and no error row. The adapter draws through
// [SeatRenderers.deckPanel]: nothing outside ui/ imports ui/.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../seat_inventory.dart';
import '../seat_models.dart';
import '../seat_planner.dart';
import '../seat_state.dart';
import '../slot_catalog.dart';

class DeckPanelAdapter implements NativeSlotAdapter {
  const DeckPanelAdapter();

  @override
  String get id => 'deck-panel';

  @override
  Set<String> get slots => const {Slots.rightPaneTab};

  @override
  bool canRender(SlotOccupant o, PluginClientInfo info) => o.cell == SeatInventory.deckPanelCell;

  @override
  NativeCoverage coverage(SlotOccupant o) => NativeCoverage.full;

  @override
  Widget build(BuildContext context, SeatContext seat, SlotOccupant o) {
    final sessionId = seat.sessionId;
    return sessionId == null ? const SizedBox.shrink() : _DeckPanelSeat(sessionId: sessionId);
  }
}

class _DeckPanelSeat extends ConsumerWidget {
  const _DeckPanelSeat({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draw = ref.watch(seatRenderersProvider.select((r) => r.deckPanel));
    return draw == null ? const SizedBox.shrink() : draw(context, sessionId);
  }
}
