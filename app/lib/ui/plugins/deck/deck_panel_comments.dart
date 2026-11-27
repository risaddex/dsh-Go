import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/deck/deck_panel_comments_state.dart';
import '../../common/app_sheet.dart' show groupTitleStyle;

/// Read on demand, and keep pages only while this ticket and reader are shown.
class DeckPanelComments extends ConsumerWidget {
  const DeckPanelComments({super.key, required this.sessionId, required this.ticketKey});

  final String sessionId;
  final String ticketKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reader = ref.watch(deckPanelCommentsReaderProvider);
    if (reader == null) return const SizedBox.shrink();
    return _Comments(
      key: ValueKey((reader, sessionId, ticketKey)),
      read: ({cursor}) => reader(sessionId, ticketKey, cursor: cursor),
    );
  }
}

class _Comments extends StatefulWidget {
  const _Comments({super.key, required this.read});

  final Future<DeckCommentsPage> Function({String? cursor}) read;

  @override
  State<_Comments> createState() => _CommentsState();
}

class _CommentsState extends State<_Comments> {
  final _comments = <DeckComment>[];
  String? _cursor;
  bool _started = false;
  bool _loading = false;
  bool _failed = false;
  bool _truncated = false;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.read(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _comments.addAll(page.comments);
        _cursor = page.nextCursor;
        _truncated = _truncated || page.truncated;
        _started = true;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(header: true, child: Text(l10n.deckPanelCommentsTitle, style: groupTitleStyle(context))),
          const SizedBox(height: 8),
          if (_started && _comments.isEmpty && _cursor == null && !_truncated) Text(l10n.deckPanelCommentsEmpty),
          for (final comment in _comments)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (comment.author case final author? when author.isNotEmpty)
                    Text(author, style: textTheme.titleSmall),
                  if ((comment.createdAt ?? comment.updatedAt) case final date? when date.isNotEmpty)
                    Text(_displayDate(context, date), style: textTheme.bodySmall),
                  SelectableText(comment.body),
                ],
              ),
            ),
          if (_truncated) Text(l10n.deckPanelCommentsTruncated),
          if (_failed) Text(l10n.deckPanelCommentsError),
          if (_loading)
            LinearProgressIndicator(semanticsLabel: l10n.deckPanelCommentsLoading)
          else if (_failed || !_started || _cursor != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: _load,
                child: Text(
                  _failed
                      ? l10n.deckPanelRetry
                      : _started
                      ? l10n.deckPanelCommentsMore
                      : l10n.deckPanelCommentsOpen,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _displayDate(BuildContext context, String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return value;
  final l10n = MaterialLocalizations.of(context);
  return '${l10n.formatShortDate(date)} · ${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
}
