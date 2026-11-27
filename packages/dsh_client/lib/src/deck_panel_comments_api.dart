/// The independently negotiated, read-only comments channel for Deck tickets.
library;

import 'dart:convert';

import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

const deckPanelCommentsFeature = 'deck.panel.comments.v1';
const deckPanelCommentsEndpoint = 'deck.panel.comments';
const deckCommentsPageSize = 50;
const deckCommentsReplyMaxBytes = 262144;

final class DeckComment {
  const DeckComment({
    required this.body,
    this.author,
    this.createdAt,
    this.updatedAt,
  });

  final String body;
  final String? author;
  final String? createdAt;
  final String? updatedAt;

  static DeckComment _from(Object? json) {
    final map = asMap(json);
    final body = map?['body'];
    if (map == null || body is! String) throw _protocolError('invalid comment');
    return DeckComment(
      body: body,
      author: _optionalString(map, 'author'),
      createdAt: _optionalString(map, 'createdAt'),
      updatedAt: _optionalString(map, 'updatedAt'),
    );
  }
}

final class DeckCommentsPage {
  const DeckCommentsPage({
    required this.comments,
    this.nextCursor,
    this.truncated = false,
  });

  final List<DeckComment> comments;
  final String? nextCursor;
  final bool truncated;
}

DshProtocolException _protocolError(String reason) =>
    DshProtocolException('Invalid Deck comments reply: $reason');

String? _optionalString(JsonMap map, String field) {
  if (!map.containsKey(field)) return null;
  final value = map[field];
  if (value is! String) throw _protocolError('invalid $field');
  return value;
}

extension DeckPanelCommentsApi on DshClient {
  /// This does not imply `deck.panel.read.v1` (or vice versa).
  bool get supportsDeckPanelComments =>
      carrier.peerCapabilities?.contains(deckPanelCommentsFeature) ?? false;

  /// Read up to 50 comments for the exact [key] in [sessionId]'s workspace.
  /// Pass the previous page's opaque [cursor] unchanged to continue.
  Future<DeckCommentsPage> readDeckComments(
    String sessionId,
    String key, {
    String? cursor,
  }) async {
    if (!supportsDeckPanelComments) {
      throw const DshRemoteException(
        'METHOD_NOT_ALLOWED',
        'The Host did not announce Deck comments',
      );
    }
    final reply = asMap(
      await rpc.call(deckPanelCommentsEndpoint, {
        'sessionId': sessionId,
        'key': key,
        if (cursor != null) 'cursor': cursor,
      }),
    );
    if (reply == null) throw _protocolError('not an object');
    if (utf8.encode(jsonEncode(reply)).length > deckCommentsReplyMaxBytes)
      throw _protocolError('reply too large');
    if (reply['ok'] == false) {
      final error = asMapOrEmpty(reply['error']);
      throw DshRemoteException(
        asString(error['kind']) ?? 'read-failed',
        asString(error['message']) ?? 'The Deck comments read failed',
      );
    }
    if (reply['ok'] != true) throw _protocolError('no ok flag');
    if (reply['sessionId'] != sessionId)
      throw _protocolError('another session');
    if (reply['key'] != key) throw _protocolError('another ticket');
    final comments = reply['comments'];
    if (comments is! List || comments.length > deckCommentsPageSize)
      throw _protocolError('invalid comments page');
    final nextCursor = _optionalString(reply, 'nextCursor');
    if (nextCursor != null && (nextCursor.isEmpty || nextCursor == cursor))
      throw _protocolError('invalid next cursor');
    final truncated = reply['truncated'];
    if (reply.containsKey('truncated') && truncated is! bool)
      throw _protocolError('invalid truncated flag');
    return DeckCommentsPage(
      comments: List.unmodifiable(comments.map(DeckComment._from)),
      nextCursor: nextCursor,
      truncated: truncated == true,
    );
  }
}
