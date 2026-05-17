import 'dart:convert';

import 'claude_models.dart';

/// Parses a `.jsonl` session file as written by the Claude Code CLI.
///
/// Each line is a JSON object with at minimum `type` and `message`. We try
/// hard to be tolerant: unknown line types are skipped, malformed JSON is
/// skipped, and unknown content blocks are turned into best-effort text.
class ClaudeJsonlParser {
  ClaudeJsonlParser._();

  /// Parse a whole file's worth of JSONL into a list of [ClaudeMessage]s.
  static List<ClaudeMessage> parseAll(String body) {
    final out = <ClaudeMessage>[];
    for (final line in const LineSplitter().convert(body)) {
      if (line.trim().isEmpty) continue;
      final msg = parseLine(line);
      if (msg != null) out.add(msg);
    }
    return out;
  }

  /// Parse a single JSONL line. Returns `null` for malformed or
  /// unrecognised lines.
  static ClaudeMessage? parseLine(String line) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final type = (json['type'] as String?) ?? 'unknown';

    // `cwd` lives at the top level of every event Claude Code emits,
    // regardless of `type`. Extract once so every branch carries it.
    final cwd = json['cwd'] as String?;

    if (type == 'summary') {
      return ClaudeMessage(
        uuid: json['uuid'] as String?,
        parentUuid: json['parentUuid'] as String?,
        role: 'summary',
        type: 'summary',
        timestamp: _ts(json['timestamp']),
        blocks: const [],
        cwd: cwd,
        summary: (json['summary'] as String?) ?? '',
      );
    }

    // user / assistant / system → look at the wrapped `message` object.
    final message = json['message'];
    if (message is! Map<String, dynamic>) {
      // Some lines (e.g. tool_use_request markers) lack message; surface as
      // an empty text block of the line type so they show up if needed.
      return ClaudeMessage(
        uuid: json['uuid'] as String?,
        parentUuid: json['parentUuid'] as String?,
        role: type,
        type: type,
        timestamp: _ts(json['timestamp']),
        blocks: const [],
        cwd: cwd,
      );
    }

    final role = (message['role'] as String?) ?? type;
    final model = message['model'] as String?;
    final blocks = _parseContent(message['content']);

    return ClaudeMessage(
      uuid: json['uuid'] as String?,
      parentUuid: json['parentUuid'] as String?,
      role: role,
      type: type,
      timestamp: _ts(json['timestamp']),
      blocks: blocks,
      model: model,
      isSidechain: (json['isSidechain'] as bool?) ?? false,
      cwd: cwd,
    );
  }

  /// Best-effort `content` parser. Anthropic's API uses an array of blocks
  /// (text, tool_use, tool_result, image, thinking); Claude Code also
  /// occasionally writes a plain string.
  static List<ClaudeBlock> _parseContent(Object? raw) {
    if (raw == null) return const [];
    if (raw is String) {
      if (raw.isEmpty) return const [];
      return [ClaudeTextBlock(raw)];
    }
    if (raw is List) {
      final out = <ClaudeBlock>[];
      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;
        final block = _parseBlock(item);
        if (block != null) out.add(block);
      }
      return out;
    }
    return const [];
  }

  static ClaudeBlock? _parseBlock(Map<String, dynamic> b) {
    switch (b['type']) {
      case 'text':
        final t = b['text'] as String?;
        if (t == null || t.isEmpty) return null;
        return ClaudeTextBlock(t);
      case 'thinking':
        final t = b['thinking'] as String? ?? b['text'] as String?;
        return ClaudeThinkingBlock(t ?? '');
      case 'tool_use':
        return ClaudeToolUseBlock(
          id: (b['id'] as String?) ?? '',
          name: (b['name'] as String?) ?? 'tool',
          input: (b['input'] as Map<String, dynamic>?) ?? const {},
        );
      case 'tool_result':
        return ClaudeToolResultBlock(
          toolUseId: (b['tool_use_id'] as String?) ?? '',
          content: _flattenToolResultContent(b['content']),
          isError: (b['is_error'] as bool?) ?? false,
        );
      case 'image':
        final source = b['source'];
        String? mediaType;
        if (source is Map) {
          mediaType = source['media_type'] as String?;
        }
        return ClaudeImageBlock(
          mediaType: mediaType ?? 'image/*',
        );
      default:
        return null;
    }
  }

  /// `tool_result.content` may itself be a string OR a list of blocks. We
  /// flatten to a single string for compact rendering.
  static String _flattenToolResultContent(Object? raw) {
    if (raw == null) return '';
    if (raw is String) return raw;
    if (raw is List) {
      final parts = <String>[];
      for (final item in raw) {
        if (item is Map && item['type'] == 'text') {
          parts.add(item['text']?.toString() ?? '');
        } else if (item is Map) {
          parts.add(jsonEncode(item));
        } else if (item is String) {
          parts.add(item);
        }
      }
      return parts.join('\n');
    }
    return raw.toString();
  }

  static DateTime? _ts(Object? raw) {
    if (raw is String) {
      try {
        return DateTime.parse(raw);
      } catch (_) {
        return null;
      }
    }
    if (raw is num) {
      // Some writers use epoch seconds.
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000);
    }
    return null;
  }
}

/// Extract just the cheap "metadata" — first user msg, last preview,
/// message count, last timestamp — without retaining every parsed message.
/// Used by the session-list view so we don't hold whole histories in
/// memory until the user opens a session.
class ClaudeSessionMeta {
  ClaudeSessionMeta({
    required this.firstUserMessage,
    required this.lastMessagePreview,
    required this.lastMessageAt,
    required this.messageCount,
  });

  final String? firstUserMessage;
  final String? lastMessagePreview;
  final DateTime? lastMessageAt;
  final int messageCount;

  static ClaudeSessionMeta extract(String body) {
    String? firstUser;
    String? lastPreview;
    DateTime? lastAt;
    var count = 0;

    for (final line in const LineSplitter().convert(body)) {
      if (line.trim().isEmpty) continue;
      final msg = ClaudeJsonlParser.parseLine(line);
      if (msg == null) continue;
      count++;
      if (msg.timestamp != null) lastAt = msg.timestamp;
      final text = _firstText(msg);
      if (text != null && text.trim().isNotEmpty) {
        lastPreview = text;
        firstUser ??= msg.type == 'user' ? text : firstUser;
      }
    }

    return ClaudeSessionMeta(
      firstUserMessage: firstUser,
      lastMessagePreview: lastPreview,
      lastMessageAt: lastAt,
      messageCount: count,
    );
  }

  static String? _firstText(ClaudeMessage m) {
    for (final b in m.blocks) {
      if (b is ClaudeTextBlock) return b.text;
    }
    return null;
  }
}
