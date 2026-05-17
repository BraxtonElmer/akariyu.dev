/// Represents one project directory under `~/.claude/projects/`.
///
/// Claude Code encodes the project's working directory by replacing `/`
/// with `-`. So `/home/elmer/projects/akariyu.dev` becomes
/// `-home-elmer-projects-akariyu.dev`. Decoding is ambiguous (since paths
/// can contain `-`); we keep the raw form authoritative and produce a
/// best-effort display path for the UI.
class ClaudeProject {
  ClaudeProject({
    required this.encodedDirName,
    required this.absoluteDir,
    required this.sessionCount,
    required this.lastModified,
    this.cwd,
  });

  /// Raw directory name on disk, e.g. `-home-elmer-projects-akariyu.dev`.
  final String encodedDirName;

  /// Absolute path on the server: `<claudeProjectsRoot>/<encodedDirName>`.
  final String absoluteDir;

  /// Number of `.jsonl` sessions in this project.
  final int sessionCount;

  /// Newest mtime across the sessions, for sorting "most recently used".
  final DateTime? lastModified;

  /// Actual working directory of this project, read from any session's
  /// `cwd` field. Authoritative — the directory name itself encodes both
  /// `/` and `.` as `-`, which is irreversibly ambiguous.
  final String? cwd;

  /// Path to display in the UI. Prefers the JSONL `cwd` (always accurate)
  /// and falls back to a best-effort decode of the dir name.
  String get displayPath {
    if (cwd != null && cwd!.isNotEmpty) return cwd!;
    if (encodedDirName.isEmpty) return encodedDirName;
    final body = encodedDirName.startsWith('-')
        ? encodedDirName.substring(1)
        : encodedDirName;
    return '/${body.replaceAll('-', '/')}';
  }

  String get displayName {
    final path = displayPath;
    final last = path.split('/').where((s) => s.isNotEmpty).toList();
    return last.isEmpty ? path : last.last;
  }
}

/// One session within a project — one `.jsonl` file.
class ClaudeSession {
  ClaudeSession({
    required this.id,
    required this.projectDir,
    required this.fileName,
    required this.absolutePath,
    required this.firstUserMessage,
    required this.lastMessagePreview,
    required this.lastMessageAt,
    required this.messageCount,
  });

  /// UUID portion of the file name (everything before `.jsonl`).
  final String id;

  /// Encoded project directory (used to derive the absolute path).
  final String projectDir;

  /// Filename on disk, e.g. `<uuid>.jsonl`.
  final String fileName;

  final String absolutePath;

  /// First user message text — used to auto-title the session.
  final String? firstUserMessage;

  /// Short preview of the most recent message.
  final String? lastMessagePreview;

  /// Timestamp of the last event in the JSONL.
  final DateTime? lastMessageAt;

  final int messageCount;

  String get title {
    final m = firstUserMessage?.trim();
    if (m == null || m.isEmpty) return 'Untitled session';
    final firstLine = m.split('\n').first.trim();
    if (firstLine.length <= 60) return firstLine;
    return '${firstLine.substring(0, 60)}…';
  }
}

/// One parsed message in a chat (a single line in the JSONL).
class ClaudeMessage {
  ClaudeMessage({
    required this.uuid,
    required this.parentUuid,
    required this.role,
    required this.type,
    required this.timestamp,
    required this.blocks,
    this.model,
    this.isSidechain = false,
    this.cwd,
    this.summary,
  });

  final String? uuid;
  final String? parentUuid;

  /// `user` | `assistant` | `system` | `summary` | `tool_result` (rare).
  final String role;

  /// `user` | `assistant` | `system` | `summary` — the top-level `type` field.
  /// Distinct from [role]: a `user` line can carry tool_result content.
  final String type;

  final DateTime? timestamp;
  final List<ClaudeBlock> blocks;
  final String? model;
  final bool isSidechain;
  final String? cwd;
  final String? summary;

  bool get isUser => type == 'user';
  bool get isAssistant => type == 'assistant';
  bool get isSummary => type == 'summary';
}

/// Discriminated union for the rich content inside a [ClaudeMessage].
sealed class ClaudeBlock {
  const ClaudeBlock();
}

class ClaudeTextBlock extends ClaudeBlock {
  const ClaudeTextBlock(this.text);
  final String text;
}

class ClaudeThinkingBlock extends ClaudeBlock {
  const ClaudeThinkingBlock(this.text);
  final String text;
}

class ClaudeToolUseBlock extends ClaudeBlock {
  const ClaudeToolUseBlock({
    required this.id,
    required this.name,
    required this.input,
  });
  final String id;
  final String name;
  final Map<String, dynamic> input;
}

class ClaudeToolResultBlock extends ClaudeBlock {
  const ClaudeToolResultBlock({
    required this.toolUseId,
    required this.content,
    this.isError = false,
  });
  final String toolUseId;
  final String content;
  final bool isError;
}

class ClaudeImageBlock extends ClaudeBlock {
  const ClaudeImageBlock({required this.mediaType, this.dataSummary});
  final String mediaType;
  final String? dataSummary;
}
