// The label pill in the deck panel (ui/common/label_chip.dart): a label the
// tracker gave a colour is drawn in that colour, and a label it left without
// one keeps the neutral chip the panel has always drawn.
//
// This is the seam that was broken in the panel: the deck already sent
// {name, color} per label (deck.panel.read.v1) and the app parsed the colour,
// then painted every chip with a fixed idle tone, so every label on a phone
// looked colourless while the same workspace showed colours on the desktop.

import 'package:dsh_app/ui/common/label_chip.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('labelColorOf', () {
    test('reads the six hex digits with or without a hash, in any case', () {
      expect(labelColorOf('eb5757'), const Color(0xFFEB5757));
      expect(labelColorOf('#EB5757'), const Color(0xFFEB5757));
      expect(labelColorOf('  #0ea5e9  '), const Color(0xFF0EA5E9));
    });

    test('answers null for everything that is not a colour', () {
      expect(labelColorOf(''), isNull, reason: 'a label with no colour carries an empty string');
      expect(labelColorOf('   '), isNull);
      expect(labelColorOf('8b5cf'), isNull, reason: 'five digits');
      expect(labelColorOf('8b5cf6ff'), isNull, reason: 'eight digits');
      expect(labelColorOf('gggggg'), isNull);
      expect(labelColorOf('wayfinder:research'), isNull);
    });
  });

  Future<void> pump(WidgetTester tester, Widget chip) => tester.pumpWidget(
    MaterialApp(theme: buildLightTheme(), home: Scaffold(body: Center(child: chip))),
  );

  Text labelled(WidgetTester tester, String text) => tester.widget<Text>(find.text(text));

  testWidgets('a label with a colour is drawn in that colour', (tester) async {
    await pump(tester, const LabelChip(name: 'bug', colorHex: 'eb5757'));
    expect(labelled(tester, 'bug').style?.color, const Color(0xFFEB5757));
    expect(find.byType(StatusChip), findsNothing, reason: 'a coloured label is not the neutral chip');
  });

  testWidgets('a label with no colour keeps the neutral chip', (tester) async {
    await pump(tester, const LabelChip(name: 'sem-cor', colorHex: ''));
    expect(find.byType(StatusChip), findsOneWidget);
    expect(find.text('sem-cor'), findsOneWidget);
  });

  testWidgets('a colour too light to read does not make the text invisible', (tester) async {
    await pump(tester, const LabelChip(name: 'clarinho', colorHex: 'ededed'));
    final colour = labelled(tester, 'clarinho').style?.color;
    expect(colour, isNotNull);
    expect(colour, isNot(const Color(0xFFEDEDED)), reason: 'the neutral text colour takes over');
  });
}
