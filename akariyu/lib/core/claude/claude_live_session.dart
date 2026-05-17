import 'dart:convert';

import '../ssh/sftp_service.dart';
import '../ssh/ssh_service.dart';

/// User-facing config knobs for a single send.
class ClaudeSendConfig {
  const ClaudeSendConfig({
    this.model = 'default',
    this.permissionMode = 'default',
  });

  /// `default`, `opus`, `sonnet`, `haiku`, or a fully-qualified model id
  /// like `claude-opus-4-7`. `default` lets Claude Code pick from
  /// `~/.claude/settings.json`.
  final String model;

  /// `default`, `acceptEdits`, `bypassPermissions`, `plan`.
  final String permissionMode;

  ClaudeSendConfig copyWith({String? model, String? permissionMode}) =>
      ClaudeSendConfig(
        model: model ?? this.model,
        permissionMode: permissionMode ?? this.permissionMode,
      );

  Map<String, String> toJson() => {
        'model': model,
        'permissionMode': permissionMode,
      };

  static ClaudeSendConfig fromJson(Map<String, dynamic> j) => ClaudeSendConfig(
        model: (j['model'] as String?) ?? 'default',
        permissionMode: (j['permissionMode'] as String?) ?? 'default',
      );

  String encode() => jsonEncode(toJson());
  static ClaudeSendConfig decode(String s) {
    try {
      return fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const ClaudeSendConfig();
    }
  }
}

/// Result of a one-shot `claude -p` invocation.
class ClaudeSendResult {
  ClaudeSendResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// Runs Claude Code one message at a time via SSH. Each [sendMessage]
/// shells out to `claude --resume <id> -p` and blocks until Claude is done
/// — no tmux paste-buffer races, no "is the TUI ready" guessing. After
/// the SSH call returns, the chat view re-reads the JSONL (which Claude
/// has just appended to) to render the new turns.
///
/// Live token streaming + interactive permission popups arrive in 2.2.2 /
/// 2.2.3 on top of this primitive (by running through tmux + pipe-pane).
class ClaudeLiveSession {
  ClaudeLiveSession({
    required this.ssh,
    required this.sftp,
    required this.sessionId,
    required this.cwd,
  });

  final SshConnection ssh;
  final SftpService sftp;
  final String sessionId;
  final String cwd;

  Future<ClaudeSendResult> sendMessage(
    String text, {
    ClaudeSendConfig config = const ClaudeSendConfig(),
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (text.isEmpty) {
      throw ClaudeLiveSessionException('Empty message');
    }

    // Stage the prompt in a tmp file so we don't need to shell-escape
    // multi-line / special-character content.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final stagePath = '/tmp/akariyu-msg-$stamp.txt';
    await sftp.writeText(stagePath, text);

    final cdPart = cwd.isEmpty ? '' : 'cd ${_sh(cwd)} && ';
    final modelPart =
        config.model == 'default' ? '' : '--model ${_sh(config.model)} ';
    final permissionPart = config.permissionMode == 'default'
        ? ''
        : '--permission-mode ${_sh(config.permissionMode)} ';

    final cmd =
        '${cdPart}claude --resume ${_sh(sessionId)} '
        '$modelPart$permissionPart-p < ${_sh(stagePath)} 2>&1';

    try {
      final res = await ssh.run(cmd, timeout: timeout);
      return ClaudeSendResult(
        exitCode: res.exitCode,
        stdout: res.stdout,
        stderr: res.stderr,
      );
    } finally {
      try {
        await ssh.run('rm -f ${_sh(stagePath)}',
            timeout: const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  String _sh(String v) => "'${v.replaceAll("'", r"'\''")}'";
}

class ClaudeLiveSessionException implements Exception {
  ClaudeLiveSessionException(this.message);
  final String message;
  @override
  String toString() => 'ClaudeLiveSessionException: $message';
}

/// Snapshot of the JSONL file's freshness — used by polling.
class ClaudeSessionStat {
  ClaudeSessionStat({required this.mtime, required this.size});
  final DateTime? mtime;
  final int size;

  @override
  bool operator ==(Object other) =>
      other is ClaudeSessionStat &&
      other.mtime == mtime &&
      other.size == size;
  @override
  int get hashCode => Object.hash(mtime, size);
}

/// One shot of mtime+size via SSH `stat`. Works on GNU coreutils; falls
/// back to BSD `stat -f` for macOS / FreeBSD servers.
Future<ClaudeSessionStat?> statSessionFile(
    SshConnection ssh, String absolutePath) async {
  final escaped = _shEscape(absolutePath);
  // Try GNU first, then BSD. The `||` chain prints exactly one line.
  final res = await ssh.run(
    "stat -c '%Y %s' $escaped 2>/dev/null "
    "|| stat -f '%m %z' $escaped 2>/dev/null",
    timeout: const Duration(seconds: 3),
  );
  final lines = const LineSplitter().convert(res.stdout);
  if (lines.isEmpty) return null;
  final parts = lines.first.trim().split(' ');
  if (parts.length < 2) return null;
  final mtimeSec = int.tryParse(parts[0]);
  final size = int.tryParse(parts[1]);
  if (mtimeSec == null || size == null) return null;
  return ClaudeSessionStat(
    mtime: DateTime.fromMillisecondsSinceEpoch(mtimeSec * 1000),
    size: size,
  );
}

String _shEscape(String v) => "'${v.replaceAll("'", r"'\''")}'";
