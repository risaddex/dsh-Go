// A label pill that carries the tracker's own colour.
//
// The deck panel receives one {name, color} pair per label (deck.panel.read.v1)
// and the colour is whatever the tracker wrote there: Linear answers #EB5757,
// GitHub answers eb5757, and a label nobody gave a colour answers an empty
// string. The app owns the single place that decides what a usable colour is,
// so every screen that shows a label agrees on the answer.
//
// Why a colourless label keeps the neutral chip instead of inventing a hue:
// the panel's rule (deck #99) is that a label with no colour is drawn neutral
// grey, not picked from a palette. Here that means `StatusTone.idle`, which is
// the chip this screen has always drawn for labels, so the only visible change
// is that coloured labels stop looking grey.

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'status_chip.dart';

/// The colour [hex] names, or null when it names none.
///
/// Accepts six hex digits with or without a leading `#`, in any case, because
/// that is every shape the trackers and the deck send. Anything else — the
/// empty string a colourless label carries, a half-written value, a name — is
/// null: the caller must then draw the neutral chip rather than guess a colour.
Color? labelColorOf(String hex) {
  final text = hex.trim();
  final digits = text.startsWith('#') ? text.substring(1) : text;
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(digits)) return null;
  return Color(0xFF000000 | int.parse(digits, radix: 16));
}

/// One label, painted with its own colour when it has one.
class LabelChip extends StatelessWidget {
  const LabelChip({super.key, required this.name, required this.colorHex});

  final String name;

  /// The tracker's colour for this label; empty when it has none.
  final String colorHex;

  @override
  Widget build(BuildContext context) {
    final color = labelColorOf(colorHex);
    if (color == null) return StatusChip(tone: StatusTone.idle, label: name);

    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // Text in the label's own hue, except when that hue is too light to read on
    // a tinted pill: those fall back to the chip's neutral text colour instead
    // of staying invisible.
    final readable = color.computeLuminance() > 0.70 ? DshColors.of(context).textTertiary : color;
    return AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      constraints: const BoxConstraints(minHeight: StatusChip.height),
      padding: const EdgeInsets.symmetric(horizontal: StatusChip.padding),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: dark ? 0.20 : 0.14),
        shape: StadiumBorder(side: BorderSide(color: color.withValues(alpha: dark ? 0.55 : 0.45))),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: ShapeDecoration(color: readable, shape: const CircleBorder()),
            child: const SizedBox.square(dimension: 6),
          ),
          const SizedBox(width: 6),
          Text(
            name,
            maxLines: 1,
            softWrap: false,
            style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: readable, height: 1.2)),
          ),
        ],
      ),
    );
  }
}
