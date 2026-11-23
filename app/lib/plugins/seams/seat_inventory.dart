// The client inventory (plugin-seams.md §5) as the seats read it: one
// PluginClientInfo per package, occupancy with labels in the app's language,
// and the Tier A guesses for slots a package list can still name.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';
import '../../ui/engine_settings/engine_settings_page.dart' show isPluginForm;
import '../../ui/engine_settings/schema_form.dart' show schemaSections;
import '../native/native_model.dart' show NativePanel;
import 'seat_models.dart';
import 'slot_catalog.dart';

/// Packages and slot occupancy of the active host.
@immutable
class SeatInventory {
  const SeatInventory({
    this.tier = ClientInventoryTier.bundles,
    this.release,
    this.bootRev,
    this.packages = const {},
    this.occupancy,
    this.occupancyStale = false,
    this.routeGuard = false,
    this.webReachable = false,
    this.nativePanels = const [],
    this.deckPanel = false,
  });

  static const empty = SeatInventory();

  /// The deck's own read-only panel (deck.panel.read.v1) is not a plugin
  /// declaration: the host announced a feature, so the app seats it itself,
  /// under the deck's package name.
  static const deckPackage = 'dsh-skills-deck';
  static const deckPanelCell = 'deck-read:panel';

  /// Cells of the native panels' occupants: `dsh-go:<panel id>`.
  static const nativeCellPrefix = 'dsh-go:';

  /// The panel id of a native occupant's [cell]; null for any other cell.
  static String? nativePanelId(String cell) =>
      cell.startsWith(nativeCellPrefix) ? cell.substring(nativeCellPrefix.length) : null;

  /// [inventory] with each package's drawable settings namespaces taken from
  /// [namespaces] (`settings/describe`, null while unknown).
  factory SeatInventory.from(
    ClientInventory inventory, {
    Map<String, SettingsNamespaceView>? namespaces,
    bool webReachable = false,
    String locale = 'zh',
    List<NativePanel> nativePanels = const [],
    bool deckPanel = false,
  }) {
    return SeatInventory(
      tier: inventory.tier,
      release: inventory.release?.version,
      bootRev: inventory.bootRev,
      packages: {
        for (final p in inventory.packages.values)
          p.name: PluginClientInfo(
            package: p.name,
            hasClient: p.hasClient,
            rev: p.rev,
            official: p.official,
            enabled: p.enabled,
            installed: p.installed,
            version: p.version,
            rowIds: p.rowIds,
            configNamespaces: [
              if (namespaces != null)
                for (final row in p.rowIds)
                  if (namespaces[row] case final view? when isPluginForm(view)) row,
            ],
            fallbackNamespaces: [
              if (namespaces != null)
                for (final row in p.rowIds)
                  if (namespaces[row] case final view? when !isPluginForm(view) && schemaSections(view).isNotEmpty) row,
            ],
            panels: p.panels,
            pet: p.pet,
          ),
      },
      occupancy: inventory.slots?.map(
        (slot, list) => MapEntry(slot, [
          for (final o in list)
            SlotOccupant(
              slot: slot,
              package: o.package,
              cell: o.cell,
              order: o.order,
              label: o.label?.resolve(locale),
              official: o.official,
            ),
        ]),
      ),
      occupancyStale: inventory.occupancyStale,
      routeGuard: inventory.routeGuard,
      webReachable: webReachable,
      nativePanels: nativePanels,
      deckPanel: deckPanel,
    );
  }

  final ClientInventoryTier tier;

  /// DSH release label of the host.
  final String? release;
  final String? bootRev;
  final Map<String, PluginClientInfo> packages;

  /// Tier B slot → occupants (official ones included); null when the bridge
  /// is missing or no page has reported yet.
  final Map<String, List<SlotOccupant>>? occupancy;

  /// The bridge's table is missing or belongs to another boot graph.
  final bool occupancyStale;

  /// The host's plugin routes are guarded: required for islands on the
  /// local engine.
  final bool routeGuard;

  /// The host serves DSH Web to this connection.
  final bool webReachable;

  /// Native panels the host's plugins declare (switched-on ones): they
  /// occupy 对话详情's 「插件」 tab (`session.tab`) and 全部功能 (`features`)
  /// as cells `dsh-go:<id>`, ahead of their package's web entries.
  final List<NativePanel> nativePanels;

  /// The connected host announced `deck.panel.read.v1`: the deck panel
  /// occupies 对话详情's 「插件」 tab.
  final bool deckPanel;

  /// The native panel behind [package]'s [cell], if it is one.
  NativePanel? nativePanel(String package, String cell) {
    final id = nativePanelId(cell);
    if (id == null) return null;
    return nativePanels.where((p) => p.package == package && p.id == id).firstOrNull;
  }

  /// The bridge is there but needs a probe island to refresh its table.
  bool get needsProbe => tier == ClientInventoryTier.bridge && occupancyStale;

  PluginClientInfo infoOf(String package) => packages[package] ?? PluginClientInfo.assumed(package);

  bool isOfficial(String package) => packages[package]?.official ?? isOfficialPackageName(package);

  /// The occupants of [slot] (official ones included; the planner skips
  /// them): the bridge's table, plus Tier A guesses while that table is
  /// missing or stale. [package] and [cell] narrow the list.
  List<SlotOccupant> occupantsFor(String slot, {String? package, String? cell}) {
    final reported = occupancy?[slot] ?? const <SlotOccupant>[];
    final guessed = occupancy == null || occupancyStale ? _inferred(slot) : const <SlotOccupant>[];
    final seen = <(String, String)>{};
    return [
      for (final o in [..._native(slot), ...reported, ...guessed])
        if ((package == null || o.package == package) &&
            (cell == null || o.cell == cell) &&
            seen.add((o.package, o.cell)))
          o,
    ];
  }

  List<SlotOccupant> _native(String slot) => [..._nativePanelOccupants(slot), ..._deckOccupant(slot)];

  List<SlotOccupant> _deckOccupant(String slot) => deckPanel && slot == Slots.rightPaneTab
      ? [SlotOccupant(slot: slot, package: deckPackage, cell: deckPanelCell, label: appL10n.deckPanelTitle)]
      : const [];

  List<SlotOccupant> _nativePanelOccupants(String slot) {
    if (nativePanels.isEmpty) return const [];
    final placement = switch (slot) {
      Slots.rightPaneTab => DshGoPanel.sessionTab,
      Slots.main => DshGoPanel.features,
      Slots.dshGoPanel => '',
      _ => null,
    };
    if (placement == null) return const [];
    return [
      for (final p in nativePanels)
        if (placement.isEmpty || p.placement.contains(placement))
          SlotOccupant(slot: slot, package: p.package, cell: '$nativeCellPrefix${p.id}', label: p.title),
    ];
  }

  List<SlotOccupant> _inferred(String slot) {
    final inference = seatPolicyOf(slot).inference;
    if (inference == SlotInference.none) return const [];
    return [
      for (final p in packages.values)
        if (p.hasClient && p.installed && !p.official)
          ...switch (inference) {
            SlotInference.bundleConfig => [
              SlotOccupant(slot: slot, package: p.package, cell: p.package, inferred: true),
            ],
            SlotInference.rowConfig => [
              for (final row in p.rowIds)
                SlotOccupant(slot: slot, package: p.package, cell: '${p.package}#$row', inferred: true),
            ],
            SlotInference.none => const <SlotOccupant>[],
          },
    ];
  }
}
