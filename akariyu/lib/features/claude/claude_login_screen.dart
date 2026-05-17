import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/providers.dart';
import '../../core/tmux/terminal_session.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Full-screen wrapper that drops the user into `claude /login` (or
/// `claude` for fresh-install onboarding) inside an xterm. Because the
/// CLI's auth flow is a real TUI — banner, theme picker, T&C, URL,
/// paste-code prompt — anything other than a real terminal misses
/// frames. Pop the screen when login is done and the chat retries.
///
/// Pops with `true` when the user taps "Done" (caller should retry the
/// send); `false` on cancel.
class ClaudeLoginScreen extends ConsumerStatefulWidget {
  const ClaudeLoginScreen({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<ClaudeLoginScreen> createState() =>
      _ClaudeLoginScreenState();
}

class _ClaudeLoginScreenState extends ConsumerState<ClaudeLoginScreen> {
  TerminalSession? _session;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootShell());
  }

  Future<void> _bootShell() async {
    try {
      final mgr = ref.read(connectionManagerProvider);
      final conn = mgr.connectionFor(widget.serverId) ??
          await mgr.connect(widget.serverId);

      // Resolve the akariyu-claude shim path so we can invoke it from
      // inside the new shell once it's ready.
      final liveKey = ClaudeLiveKey(
        serverId: widget.serverId,
        sessionId: 'auth',
        cwd: '~',
      );
      final live =
          await ref.read(claudeLiveSessionProvider(liveKey).future);
      final claudePath = await live.resolveClaudePath();
      if (claudePath == null) {
        if (!mounted) return;
        setState(() => _error = 'Claude is not installed yet — install '
            'from the chat screen first, then come back here to log in.');
        return;
      }

      final session = await TerminalSession.start(
        conn: conn,
        title: 'claude /login',
        tmuxName: 'akariyu-login',
      );
      if (!mounted) {
        await session.detach();
        return;
      }
      setState(() => _session = session);

      // After a beat, type the login command so the user lands in the
      // OAuth TUI instead of a bare bash prompt.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      session.terminal.textInput('$claudePath /login\n');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _done(BuildContext context) async {
    Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    // Detach (NOT kill) so the tmux session keeps running if the user
    // bails mid-login. Re-opening this screen re-attaches via the same
    // tmuxName.
    _session?.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: const Text('Log in with Anthropic'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        actions: [
          TextButton(
            onPressed: () => _done(context),
            child: Text('Done',
                style: TextStyle(color: AkariyuColors.accent)),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: AkariyuColors.error),
            const SizedBox(height: 12),
            Text(_error!,
                style: AkariyuTypography.bodyMedium,
                textAlign: TextAlign.center),
          ],
        ),
      );
    }
    final session = _session;
    if (session == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        _Instructions(),
        Expanded(
          child: Container(
            color: AkariyuColors.backgroundBase,
            child: TerminalView(
              session.terminal,
              theme: _termTheme,
              textStyle: const TerminalStyle(
                fontFamily: 'monospace',
                fontSize: 13,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              autofocus: true,
              backgroundOpacity: 1,
              keyboardType: TextInputType.text,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: const BoxDecoration(
            color: AkariyuColors.surfaceElevated,
            border:
                Border(top: BorderSide(color: AkariyuColors.borderSubtle)),
          ),
          child: AkariyuButton(
            label: 'Done — back to chat',
            fullWidth: true,
            icon: Icons.check,
            onPressed: () => _done(context),
          ),
        ),
      ],
    );
  }
}

class _Instructions extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: AkariyuColors.surfaceCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 14, color: AkariyuColors.accent),
              const SizedBox(width: 8),
              Text('Steps',
                  style: AkariyuTypography.labelLarge.copyWith(
                    color: AkariyuColors.accent,
                  )),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '1. Accept any onboarding prompts (theme, T&C).\n'
            '2. When Claude prints a URL, tap and hold to copy it, then '
            'open it in your browser.\n'
            '3. Sign in, copy the resulting code back into the terminal '
            'below, and press Enter.\n'
            '4. Hit "Done — back to chat".',
            style: AkariyuTypography.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Color theme for the embedded xterm — matches the akariyu palette.
const _termTheme = TerminalTheme(
  cursor: AkariyuColors.accent,
  selection: AkariyuColors.accentMuted,
  foreground: AkariyuColors.textPrimary,
  background: AkariyuColors.backgroundBase,
  black: Color(0xFF1C1C1C),
  red: AkariyuColors.accent,
  green: AkariyuColors.success,
  yellow: AkariyuColors.warning,
  blue: AkariyuColors.info,
  magenta: Color(0xFFC084FC),
  cyan: Color(0xFF22D3EE),
  white: AkariyuColors.textPrimary,
  brightBlack: Color(0xFF404040),
  brightRed: Color(0xFFFF6B6B),
  brightGreen: Color(0xFF4ADE80),
  brightYellow: Color(0xFFFBBF24),
  brightBlue: Color(0xFF60A5FA),
  brightMagenta: Color(0xFFE879F9),
  brightCyan: Color(0xFF67E8F9),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: AkariyuColors.accentMuted,
  searchHitBackgroundCurrent: AkariyuColors.accent,
  searchHitForeground: AkariyuColors.textPrimary,
);
