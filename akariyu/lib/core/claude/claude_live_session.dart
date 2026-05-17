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

  String? _claudePathCache;

  /// Resolve `claude`'s absolute path on the server via a login shell so
  /// the user's full PATH (npm prefix, asdf, nvm, `~/.local/bin`, …)
  /// applies. Cached per-instance — refresh by calling [resetCache].
  ///
  /// Explicitly sources `~/.nvm/nvm.sh` in case the user's dotfiles
  /// short-circuit on non-interactive shells before nvm gets loaded.
  ///
  /// Returns the absolute path, or `null` if claude isn't installed.
  Future<String?> resolveClaudePath() async {
    final cached = _claudePathCache;
    if (cached != null) return cached.isEmpty ? null : cached;
    final res = await ssh.run(
      'bash -lc ${_sh(_withNvm("command -v claude || true"))}',
      timeout: const Duration(seconds: 5),
    );
    final path = res.stdout.trim();
    _claudePathCache = path;
    return path.isEmpty ? null : path;
  }

  /// Wraps [cmd] with the env prelude every claude invocation needs:
  ///   - source nvm if present
  ///   - prepend the per-user npm-global prefix to PATH
  /// No-op on systems that don't have either.
  String _withNvm(String cmd) {
    return r'''
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
''' +
        cmd;
  }

  /// Force a re-resolution next time. Call after an install so the cached
  /// "not found" result is invalidated.
  void resetClaudePathCache() {
    _claudePathCache = null;
  }

  Future<ClaudeSendResult> sendMessage(
    String text, {
    ClaudeSendConfig config = const ClaudeSendConfig(),
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (text.isEmpty) {
      throw ClaudeLiveSessionException('Empty message');
    }

    final claudePath = await resolveClaudePath();
    if (claudePath == null) {
      throw const ClaudeNotInstalledException();
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

    // Use bash -lc so the user's environment (api key in .bashrc, etc.)
    // is honored. Source nvm in case the user's dotfiles short-circuit
    // for non-interactive shells. Inner command is single-quoted; inner
    // single quotes escape via the canonical `'\''` idiom.
    final inner = _withNvm(
      '$cdPart${_sh(claudePath)} --resume ${_sh(sessionId)} '
      '$modelPart$permissionPart-p < ${_sh(stagePath)} 2>&1',
    );
    final wrapped = 'bash -lc ${_sh(inner)}';

    try {
      final res = await ssh.run(wrapped, timeout: timeout);
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

  /// Self-bootstrapping install: if npm is missing, install nvm + node
  /// LTS first, then install `@anthropic-ai/claude-code` globally. All
  /// without sudo — everything lands under `$HOME/.nvm`.
  ///
  /// [onChunk] receives stdout/stderr text as it arrives so the UI can
  /// render a live tail.
  Future<ClaudeSendResult> installClaude({
    void Function(String chunk)? onChunk,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    // Heredoc-style script. Strategy:
    //   1. Use nvm-installed node LTS if the system npm is missing or
    //      ancient (Node < 18).
    //   2. Point npm at a per-user prefix ($HOME/.npm-global) so global
    //      installs never need sudo, even when npm itself came from
    //      apt/dnf/pacman.
    //   3. On failure, dump the most recent npm debug log so the dialog
    //      shows something more actionable than "exit 1".
    const script = r'''
set -e
mkdir -p "$HOME/.npm-global"

NEED_NVM=false
if ! command -v npm >/dev/null 2>&1; then
  echo ">>> npm not found"
  NEED_NVM=true
else
  NODE_MAJ=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)
  if [ -z "$NODE_MAJ" ] || [ "$NODE_MAJ" -lt 18 ]; then
    echo ">>> node version too old (v${NODE_MAJ:-?}); will install LTS via nvm"
    NEED_NVM=true
  else
    echo ">>> system npm OK (node v$NODE_MAJ)"
  fi
fi

if [ "$NEED_NVM" = true ]; then
  echo ">>> installing nvm + node LTS"
  curl -fsSL -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  . "$NVM_DIR/nvm.sh"
  nvm install --lts
  nvm use --lts
fi

# Per-user global prefix avoids EACCES on system-installed npm.
npm config set prefix "$HOME/.npm-global" 2>/dev/null || true
export PATH="$HOME/.npm-global/bin:$PATH"

echo ">>> installing @anthropic-ai/claude-code"
if ! npm install -g @anthropic-ai/claude-code 2>&1; then
  echo ">>> npm install failed; tail of latest npm log:"
  LATEST_LOG=$(ls -t "$HOME/.npm/_logs" 2>/dev/null | head -1)
  if [ -n "$LATEST_LOG" ]; then
    tail -120 "$HOME/.npm/_logs/$LATEST_LOG"
  else
    echo "(no npm log found in $HOME/.npm/_logs)"
  fi
  exit 1
fi

echo ">>> verifying"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
command -v claude
claude --version
echo ">>> done"
''';
    final res = await ssh.runStreaming(
      'bash -lc ${_sh(script)}',
      onStdout: onChunk,
      onStderr: onChunk,
      timeout: timeout,
    );
    resetClaudePathCache();
    return ClaudeSendResult(
      exitCode: res.exitCode,
      stdout: res.stdout,
      stderr: res.stderr,
    );
  }

  String _sh(String v) => "'${v.replaceAll("'", r"'\''")}'";
}

class ClaudeLiveSessionException implements Exception {
  const ClaudeLiveSessionException(this.message);
  final String message;
  @override
  String toString() => 'ClaudeLiveSessionException: $message';
}

/// `claude` binary missing from the server's PATH. UI catches this and
/// offers to install via npm.
class ClaudeNotInstalledException extends ClaudeLiveSessionException {
  const ClaudeNotInstalledException()
      : super('Claude Code is not installed on this server.');
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
