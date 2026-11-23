// `deck-panel`: the deck's read-only panel (spec #70) in 对话详情's 「插件」
// tab. Its one occupant exists only while the connected host announced
// `deck.panel.read.v1` (SeatInventory.deckPanel), so a host that did not has
// no entry, no empty page and no error row.

import 'package:flutter/widgets.dart';

import '../../../ui/plugins/deck/deck_panel_view.dart';
import '../seat_inventory.dart';
import '../seat_models.dart';
import '../seat_planner.dart';
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
    if (sessionId == null) return const SizedBox.shrink();
    return DeckPanelView(sessionId: sessionId);
  }
}
