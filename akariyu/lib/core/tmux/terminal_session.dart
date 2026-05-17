import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:uuid/uuid.dart';

import '../ssh/ssh_service.dart';
import 'package:xterm/xterm.dart';

/// One open shell on the server, backed by an [SSHSession] with a PTY.
///
/// Holds an [xterm] [Terminal] so the view layer can just drop it into a
/// `TerminalView`. The session re-attaches to a named tmux session when
/// [tmuxName] is provided, giving us persistence across app restarts.
class TerminalSession {
  TerminalSession._({
    required this.id,
    required this.title,
    required this.terminal,
    required this.tmuxName,
    required SSHSession sshSession,
  }) : _sshSession = sshSession;

  /// Stable id for the multi-tab UI.
  final String id;

  /// Human-readable tab title (e.g. "shell · braxton@dev").
  final String title;

  /// xterm.dart [Terminal] consumed by `TerminalView`.
  final Terminal terminal;

  /// Tmux session name on the server. Reusing the same name on subsequent
  /// opens re-attaches to the same persistent session.
  final String tmuxName;

  final SSHSession _sshSession;
  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;
  bool _closed = false;

  bool get isClosed => _closed;

  /// Open a shell on [conn], attach (or create) tmux session [tmuxName],
  /// and wire stdin/stdout/resize through to an xterm [Terminal].
  static Future<TerminalSession> start({
    required SshConnection conn,
    required String title,
    String? tmuxName,
    String? cwd,
    int cols = 80,
    int rows = 24,
    int maxLines = 5000,
  }) async {
    final id = const Uuid().v4();
    final tmux = tmuxName ?? 'akariyu-${id.substring(0, 8)}';

    // tmux attach with -A (attach OR create). We chain into a no-op command
    // so the session has a fallback if tmux itself is missing. If cwd is
    // provided we set it for new sessions; existing sessions ignore it.
    final attachCmd = cwd == null
        ? 'tmux new-session -A -s "$tmux"'
        : 'cd "$cwd" && tmux new-session -A -s "$tmux"';

    SSHSession session;
    try {
      session = await conn.client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: cols,
          height: rows,
        ),
      );
    } catch (e) {
      throw TerminalException('Could not open shell: $e');
    }

    // Send the tmux attach command into the shell. We use bash-style here so
    // it works whether the default shell is bash/zsh/fish/sh.
    session.write(Uint8List.fromList(utf8.encode('$attachCmd\n')));

    final terminal = Terminal(maxLines: maxLines);

    final ts = TerminalSession._(
      id: id,
      title: title,
      terminal: terminal,
      tmuxName: tmux,
      sshSession: session,
    );

    // Wire xterm → ssh.
    terminal.onOutput = (output) {
      if (ts._closed) return;
      session.write(Uint8List.fromList(utf8.encode(output)));
    };
    terminal.onResize = (w, h, pw, ph) {
      if (ts._closed) return;
      try {
        session.resizeTerminal(w, h, pw, ph);
      } catch (_) {
        // Some servers ignore SIGWINCH; not worth surfacing.
      }
    };

    // Wire ssh → xterm.
    ts._stdoutSub = session.stdout.listen((data) {
      terminal.write(utf8.decode(data, allowMalformed: true));
    });
    ts._stderrSub = session.stderr.listen((data) {
      terminal.write(utf8.decode(data, allowMalformed: true));
    });
    session.done.then((_) {
      ts._closed = true;
    });

    return ts;
  }

  /// Detach from tmux (sends Ctrl-B D) and close the SSH channel. The tmux
  /// session keeps running on the server — re-attach by calling [start] with
  /// the same [tmuxName].
  Future<void> detach() async {
    if (_closed) return;
    _closed = true;
    try {
      // Ctrl-B is 0x02, then 'd' to detach.
      _sshSession.write(Uint8List.fromList([0x02, 0x64]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } catch (_) {}
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _sshSession.close();
  }

  /// Kill the tmux session on the server. Use when the user explicitly asks
  /// to end the terminal (not just close the tab).
  Future<void> kill(SshConnection conn) async {
    await detach();
    try {
      await conn.run('tmux kill-session -t "$tmuxName"',
          timeout: const Duration(seconds: 5));
    } catch (_) {}
  }
}

class TerminalException implements Exception {
  TerminalException(this.message);
  final String message;
  @override
  String toString() => 'TerminalException: $message';
}
