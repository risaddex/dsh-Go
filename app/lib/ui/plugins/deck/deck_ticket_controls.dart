import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/l10n.dart';

class DeckTicketControls extends StatelessWidget {
  const DeckTicketControls({required this.ticket, required this.onDraft, this.onNewDraft});

  final DeckTicketDetail ticket;
  final ValueChanged<String>? onDraft;
  final ValueChanged<String>? onNewDraft;

  Future<void> _openTracker(BuildContext context, Uri link) async {
    try {
      if (await launchUrl(link, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      // The system's browser is unavailable; the copy action remains usable.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.stateLinkOpenFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final link = Uri.tryParse(ticket.url);
    final webLink =
        link != null &&
            (link.scheme == 'https' || link.scheme == 'http') &&
            link.host.isNotEmpty &&
            link.userInfo.isEmpty
        ? link
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Wrap(
        spacing: 8,
        children: [
          if (!ticket.isClosed)
            for (final action in ticket.actions)
              PopupMenuButton<String>(
                tooltip: action.label,
                onSelected: (choice) {
                  switch (choice) {
                    case 'draft':
                      onDraft?.call(action.prompt);
                    case 'new':
                      onNewDraft?.call(action.prompt);
                    case 'copy':
                      unawaited(Clipboard.setData(ClipboardData(text: action.prompt)));
                  }
                },
                itemBuilder: (_) => [
                  if (onDraft != null) PopupMenuItem(value: 'draft', child: Text(l10n.deckPanelDraft)),
                  if (onNewDraft != null) PopupMenuItem(value: 'new', child: Text(l10n.deckPanelNewDraft)),
                  PopupMenuItem(value: 'copy', child: Text(l10n.deckPanelCopyPrompt)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Text(action.label, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                ),
              ),
          if (webLink != null) ...[
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: webLink.toString())),
              child: Text(l10n.deckPanelCopyLink),
            ),
            TextButton(onPressed: () => _openTracker(context, webLink), child: Text(l10n.deckPanelOpenTracker)),
          ],
        ],
      ),
    );
  }
}
