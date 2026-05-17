import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ssh/sftp_service.dart';
import '../ssh/ssh_service.dart';

void _log(String msg) {
  // ignore: avoid_print
  if (kDebugMode) print('[akariyu.claude] $msg');
}

/// User-facing config knobs for a single send. Maps roughly 1:1 to
/// `claude --help` flags. Anything not enumerated here can still be
/// passed via [rawExtraArgs].
class ClaudeSendConfig {
  const ClaudeSendConfig({
    this.model = 'default',
    this.permissionMode = 'default',
    this.maxTurns,
    this.appendSystemPrompt = '',
    this.verbose = false,
    this.allowedTools = '',
    this.disallowedTools = '',
    this.addDirs = '',
    this.mcpConfig = '',
    this.strictMcpConfig = false,
    this.dangerouslySkipPermissions = false,
    this.settingsPath = '',
    this.rawExtraArgs = '',
  });

  /// `default`, `opus`, `sonnet`, `haiku`, or a fully-qualified model id
  /// like `claude-opus-4-7`. `default` lets Claude Code pick from
  /// `~/.claude/settings.json`.
  final String model;

  /// `default`, `acceptEdits`, `bypassPermissions`, `plan`.
  final String permissionMode;

  /// Cap on the number of conversation turns in a single send. `null` =
  /// no cap (Claude Code's default).
  final int? maxTurns;

  /// Extra system prompt appended to the built-in one for this send.
  /// Empty = no addition.
  final String appendSystemPrompt;

  /// Pass `--verbose` to the CLI.
  final bool verbose;

  /// Comma-separated tool names that Claude is allowed to use
  /// (e.g. `Read,Bash`). Maps to `--allowed-tools`.
  final String allowedTools;

  /// Comma-separated tool names Claude must not use. Maps to
  /// `--disallowed-tools`.
  final String disallowedTools;

  /// Comma-separated absolute paths added as additional working dirs.
  /// Maps to repeated `--add-dir` flags.
  final String addDirs;

  /// Path to an MCP servers config (JSON). Maps to `--mcp-config`.
  final String mcpConfig;

  /// `--strict-mcp-config` — error out if any MCP server in [mcpConfig]
  /// can't be started.
  final bool strictMcpConfig;

  /// `--dangerously-skip-permissions`. Equivalent to permission mode
  /// `bypassPermissions` but using the more explicit flag.
  final bool dangerouslySkipPermissions;

  /// Path to an alternate `settings.json`. Maps to `--settings`.
  final String settingsPath;

  /// Free-form raw flags appended verbatim. Use for anything not
  /// enumerated above (`--input-format`, future flags, …). User is
  /// responsible for shell-safe quoting.
  final String rawExtraArgs;

  ClaudeSendConfig copyWith({
    String? model,
    String? permissionMode,
    int? maxTurns,
    bool clearMaxTurns = false,
    String? appendSystemPrompt,
    bool? verbose,
    String? allowedTools,
    String? disallowedTools,
    String? addDirs,
    String? mcpConfig,
    bool? strictMcpConfig,
    bool? dangerouslySkipPermissions,
    String? settingsPath,
    String? rawExtraArgs,
  }) =>
      ClaudeSendConfig(
        model: model ?? this.model,
        permissionMode: permissionMode ?? this.permissionMode,
        maxTurns: clearMaxTurns ? null : (maxTurns ?? this.maxTurns),
        appendSystemPrompt: appendSystemPrompt ?? this.appendSystemPrompt,
        verbose: verbose ?? this.verbose,
        allowedTools: allowedTools ?? this.allowedTools,
        disallowedTools: disallowedTools ?? this.disallowedTools,
        addDirs: addDirs ?? this.addDirs,
        mcpConfig: mcpConfig ?? this.mcpConfig,
        strictMcpConfig: strictMcpConfig ?? this.strictMcpConfig,
        dangerouslySkipPermissions:
            dangerouslySkipPermissions ?? this.dangerouslySkipPermissions,
        settingsPath: settingsPath ?? this.settingsPath,
        rawExtraArgs: rawExtraArgs ?? this.rawExtraArgs,
      );

  Map<String, dynamic> toJson() => {
        'model': model,
        'permissionMode': permissionMode,
        'maxTurns': maxTurns,
        'appendSystemPrompt': appendSystemPrompt,
        'verbose': verbose,
        'allowedTools': allowedTools,
        'disallowedTools': disallowedTools,
        'addDirs': addDirs,
        'mcpConfig': mcpConfig,
        'strictMcpConfig': strictMcpConfig,
        'dangerouslySkipPermissions': dangerouslySkipPermissions,
        'settingsPath': settingsPath,
        'rawExtraArgs': rawExtraArgs,
      };

  static ClaudeSendConfig fromJson(Map<String, dynamic> j) => ClaudeSendConfig(
        model: (j['model'] as String?) ?? 'default',
        permissionMode: (j['permissionMode'] as String?) ?? 'default',
        maxTurns: (j['maxTurns'] as num?)?.toInt(),
        appendSystemPrompt: (j['appendSystemPrompt'] as String?) ?? '',
        verbose: (j['verbose'] as bool?) ?? false,
        allowedTools: (j['allowedTools'] as String?) ?? '',
        disallowedTools: (j['disallowedTools'] as String?) ?? '',
        addDirs: (j['addDirs'] as String?) ?? '',
        mcpConfig: (j['mcpConfig'] as String?) ?? '',
        strictMcpConfig: (j['strictMcpConfig'] as bool?) ?? false,
        dangerouslySkipPermissions:
            (j['dangerouslySkipPermissions'] as bool?) ?? false,
        settingsPath: (j['settingsPath'] as String?) ?? '',
        rawExtraArgs: (j['rawExtraArgs'] as String?) ?? '',
      );

  String encode() => jsonEncode(toJson());
  static ClaudeSendConfig decode(String s) {
    try {
      return fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const ClaudeSendConfig();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ClaudeSendConfig &&
      other.model == model &&
      other.permissionMode == permissionMode &&
      other.maxTurns == maxTurns &&
      other.appendSystemPrompt == appendSystemPrompt &&
      other.verbose == verbose &&
      other.allowedTools == allowedTools &&
      other.disallowedTools == disallowedTools &&
      other.addDirs == addDirs &&
      other.mcpConfig == mcpConfig &&
      other.strictMcpConfig == strictMcpConfig &&
      other.dangerouslySkipPermissions == dangerouslySkipPermissions &&
      other.settingsPath == settingsPath &&
      other.rawExtraArgs == rawExtraArgs;

  @override
  int get hashCode => Object.hashAll([
        model,
        permissionMode,
        maxTurns,
        appendSystemPrompt,
        verbose,
        allowedTools,
        disallowedTools,
        addDirs,
        mcpConfig,
        strictMcpConfig,
        dangerouslySkipPermissions,
        settingsPath,
        rawExtraArgs,
      ]);
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

  String? _shimPathCache;

  /// Server-side wrapper script installed by [installClaude]. It sources
  /// nvm, prepends the user-local npm prefix, sources the API key env
  /// file, and execs `claude` — so akariyu only needs to invoke ONE
  /// reliable path instead of guessing the user's PATH every time.
  ///
  /// Path on disk: `$HOME/.local/bin/akariyu-claude`.
  static const String _shimRelativePath = '.local/bin/akariyu-claude';

  /// Returns the absolute path of the installed shim, or `null` if it
  /// hasn't been installed yet. Cached per-instance.
  ///
  /// Implementation: ask SFTP to resolve `~` and then stat the shim
  /// path. No shell semantics involved, so this works the same on every
  /// sshd / login-shell combination.
  Future<String?> resolveClaudePath() async {
    final cached = _shimPathCache;
    if (cached != null) return cached.isEmpty ? null : cached;

    String home;
    try {
      home = await sftp.resolveAbsolute('.');
    } catch (e) {
      _log('resolveClaudePath: could not resolve ~ via SFTP: $e');
      _shimPathCache = '';
      return null;
    }
    final shimPath = '$home/$_shimRelativePath';
    final exists = await sftp.exists(shimPath);
    _log('resolveClaudePath: $shimPath exists=$exists');
    if (!exists) {
      _shimPathCache = '';
      return null;
    }
    _shimPathCache = shimPath;
    return shimPath;
  }

  /// Read the current `~/.claude/settings.json` from the server. Returns
  /// the raw JSON (or `null` if the file doesn't exist). Used by the
  /// "Server settings" editor for knobs that aren't CLI flags
  /// (thinking budget, env vars, model aliases, …).
  Future<String?> readClaudeSettings() async {
    final home = await sftp.resolveAbsolute('.');
    final path = '$home/.claude/settings.json';
    if (!await sftp.exists(path)) return null;
    try {
      return await sftp.readText(path, maxBytes: 256 * 1024);
    } catch (_) {
      return null;
    }
  }

  /// Overwrite `~/.claude/settings.json` with [body]. Caller is
  /// responsible for valid JSON.
  Future<void> writeClaudeSettings(String body) async {
    final home = await sftp.resolveAbsolute('.');
    final dir = '$home/.claude';
    if (!await sftp.exists(dir)) {
      await sftp.mkdir(dir);
    }
    await sftp.writeText('$dir/settings.json', body);
  }

  /// Upload [bytes] into `~/.claude/akariyu-uploads/<ts>-<safeName>` on
  /// the server and return the absolute path. The chat input layer turns
  /// that path into an `@<path>` mention, which Claude Code expands
  /// natively as a file reference.
  Future<String> uploadAttachment({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final home = await sftp.resolveAbsolute('.');
    final dir = '$home/.claude/akariyu-uploads';
    if (!await sftp.exists(dir)) {
      // mkdir -p in two steps if .claude itself is missing.
      if (!await sftp.exists('$home/.claude')) {
        await sftp.mkdir('$home/.claude');
      }
      await sftp.mkdir(dir);
    }
    // Strip path separators / weird chars from the basename so we don't
    // accidentally create nested dirs from a user-supplied filename.
    final safe = fileName
        .split('/')
        .last
        .split(r'\')
        .last
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '$dir/$stamp-$safe';
    await sftp.writeBytes(path, bytes);
    _log('uploadAttachment: $path (${bytes.length} bytes)');
    return path;
  }

  /// Path on the server where the Anthropic API key (and any future
  /// per-session env vars) live.
  static const String authEnvPath = r'$HOME/.claude/akariyu.env';

  /// Write the Anthropic API key into [authEnvPath] in the shape the
  /// prelude can `source`. Replaces any existing file.
  Future<void> setApiKey(String apiKey) async {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      throw ClaudeLiveSessionException('API key is empty');
    }
    final mkdir = await ssh.run(
      'bash -c ${_sh(r'mkdir -p "$HOME/.claude" && chmod 700 "$HOME/.claude"')}',
      timeout: const Duration(seconds: 5),
    );
    if (!mkdir.ok) {
      throw ClaudeLiveSessionException(
        'Could not create ~/.claude: ${mkdir.stderr.trim()}',
      );
    }
    // Resolve the literal $HOME so we can SFTP-write to an absolute path.
    final homeRes = await ssh.run(
      'bash -c ${_sh(r'echo "$HOME"')}',
      timeout: const Duration(seconds: 3),
    );
    final home = homeRes.stdout.trim();
    if (home.isEmpty) {
      throw ClaudeLiveSessionException(r'Could not resolve $HOME');
    }
    final body = 'export ANTHROPIC_API_KEY=${_sh(trimmed)}\n';
    await sftp.writeText('$home/.claude/akariyu.env', body);
    await ssh.run(
      'bash -c ${_sh(r'chmod 600 "$HOME/.claude/akariyu.env"')}',
      timeout: const Duration(seconds: 3),
    );
  }

  /// Force a re-resolution next time. Call after an install so the cached
  /// "not found" result is invalidated.
  void resetClaudePathCache() {
    _shimPathCache = null;
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
    final flags = StringBuffer();
    if (config.model != 'default') {
      flags.write('--model ${_sh(config.model)} ');
    }
    if (config.permissionMode != 'default') {
      flags.write('--permission-mode ${_sh(config.permissionMode)} ');
    }
    if (config.maxTurns != null && config.maxTurns! > 0) {
      flags.write('--max-turns ${config.maxTurns} ');
    }
    if (config.appendSystemPrompt.trim().isNotEmpty) {
      flags.write(
        '--append-system-prompt ${_sh(config.appendSystemPrompt)} ',
      );
    }
    if (config.verbose) flags.write('--verbose ');
    if (config.allowedTools.trim().isNotEmpty) {
      flags.write('--allowed-tools ${_sh(config.allowedTools.trim())} ');
    }
    if (config.disallowedTools.trim().isNotEmpty) {
      flags.write(
        '--disallowed-tools ${_sh(config.disallowedTools.trim())} ',
      );
    }
    if (config.addDirs.trim().isNotEmpty) {
      for (final dir in config.addDirs
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)) {
        flags.write('--add-dir ${_sh(dir)} ');
      }
    }
    if (config.mcpConfig.trim().isNotEmpty) {
      flags.write('--mcp-config ${_sh(config.mcpConfig.trim())} ');
    }
    if (config.strictMcpConfig) flags.write('--strict-mcp-config ');
    if (config.dangerouslySkipPermissions) {
      flags.write('--dangerously-skip-permissions ');
    }
    if (config.settingsPath.trim().isNotEmpty) {
      flags.write('--settings ${_sh(config.settingsPath.trim())} ');
    }
    if (config.rawExtraArgs.trim().isNotEmpty) {
      // Trust the user — they're the ones typing the args.
      flags.write('${config.rawExtraArgs.trim()} ');
    }

    // The shim itself sources nvm + sets PATH + sources the API key
    // env file before exec'ing claude, so we can invoke it directly.
    // Still wrap in bash -c so input redirection (`< stagePath`) works.
    final inner =
        '$cdPart${_sh(claudePath)} --resume ${_sh(sessionId)} '
        '$flags-p < ${_sh(stagePath)} 2>&1';
    final wrapped = 'bash -c ${_sh(inner)}';

    try {
      final res = await ssh.run(wrapped, timeout: timeout);
      _maybeThrowAuth(res.stdout);
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

  /// Heuristic: detect Claude Code's "API key is missing or invalid"
  /// failure modes so the chat UI can surface the auth dialog instead of
  /// rendering a raw error block. We match on common substrings rather
  /// than parsing — the CLI's error shape has changed across versions.
  void _maybeThrowAuth(String stdout) {
    final lower = stdout.toLowerCase();
    final isAuth = lower.contains('401') ||
        lower.contains('invalid_api_key') ||
        lower.contains('invalid api key') ||
        lower.contains('authentication_error') ||
        lower.contains('invalid auth') ||
        lower.contains('please run /login') ||
        lower.contains('please login') ||
        lower.contains('not authenticated');
    if (isAuth) throw const ClaudeNotAuthenticatedException();
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
  # Mark LTS as the default so future shells pick it up via nvm.sh.
  nvm alias default 'lts/*'
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

echo ">>> writing akariyu shim"
mkdir -p "$HOME/.local/bin"
SHIM="$HOME/.local/bin/akariyu-claude"
cat > "$SHIM" <<'SHIMEOF'
#!/usr/bin/env bash
# Generated by akariyu — re-runs on every reinstall.
# Sources nvm + per-user npm prefix + API key env file, then execs claude.
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
[ -s "$HOME/.claude/akariyu.env" ] && . "$HOME/.claude/akariyu.env"
exec claude "$@"
SHIMEOF
chmod +x "$SHIM"

echo ">>> verifying"
"$SHIM" --version
echo ">>> done — shim at $SHIM"
''';
    final res = await ssh.runStreaming(
      'bash -lc ${_sh(script)}',
      onStdout: onChunk,
      onStderr: onChunk,
      timeout: timeout,
    );
    resetClaudePathCache();

    // Belt-and-braces verification: even if the install script reported
    // success, prove the shim actually exists on disk via SFTP before we
    // tell the UI to call this a win.
    if (res.ok) {
      final resolved = await resolveClaudePath();
      if (resolved == null) {
        return ClaudeSendResult(
          exitCode: 1,
          stdout: '${res.stdout}\n\n[akariyu] install reported success but '
              'the shim is not at ~/.local/bin/akariyu-claude — see the '
              'output above for the real error.',
          stderr: res.stderr,
        );
      }
    }
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

/// `claude` ran but Anthropic refused with a 401 / "invalid auth". UI
/// catches this and opens the API-key dialog.
class ClaudeNotAuthenticatedException extends ClaudeLiveSessionException {
  const ClaudeNotAuthenticatedException()
      : super(
          'Claude Code is not authenticated. Set ANTHROPIC_API_KEY '
          'on the server, or run `claude /login`.',
        );
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
  // Wrap in bash -c so the `2>/dev/null` redirection actually gets
  // applied by a shell (dartssh2's exec channel doesn't always run
  // commands through one).
  final inner = "stat -c '%Y %s' $escaped 2>/dev/null "
      "|| stat -f '%m %z' $escaped 2>/dev/null";
  final res = await ssh.run(
    'bash -c ${_shEscape(inner)}',
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
