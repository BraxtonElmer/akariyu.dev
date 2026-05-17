import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/providers.dart';
import '../../core/tmux/terminal_session.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Tabbed terminal screen for one server. Each tab is a [TerminalSession]
/// backed by a persistent tmux session on the server.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  int _activeIndex = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureAtLeastOneTab());
  }

  Future<void> _ensureAtLeastOneTab() async {
    final tabs = ref.read(terminalTabsProvider(widget.serverId));
    if (tabs.isEmpty) await _newTab();
  }

  Future<void> _newTab() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(terminalTabsProvider(widget.serverId).notifier).open();
      final tabs = ref.read(terminalTabsProvider(widget.serverId));
      setState(() => _activeIndex = tabs.length - 1);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeTab(int index, {bool killTmux = false}) async {
    final tabs = ref.read(terminalTabsProvider(widget.serverId));
    if (index < 0 || index >= tabs.length) return;
    final id = tabs[index].id;
    await ref
        .read(terminalTabsProvider(widget.serverId).notifier)
        .closeTab(id, killTmux: killTmux);
    final newTabs = ref.read(terminalTabsProvider(widget.serverId));
    setState(() {
      _activeIndex =
          newTabs.isEmpty ? 0 : _activeIndex.clamp(0, newTabs.length - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(terminalTabsProvider(widget.serverId));
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          IconButton(
            tooltip: 'New tab',
            icon: const Icon(Icons.add),
            onPressed: _busy ? null : _newTab,
          ),
          if (tabs.isNotEmpty)
            PopupMenuButton<String>(
              color: AkariyuColors.surfaceElevated,
              icon: const Icon(Icons.more_vert),
              onSelected: (v) async {
                switch (v) {
                  case 'close':
                    await _closeTab(_activeIndex);
                    break;
                  case 'kill':
                    await _closeTab(_activeIndex, killTmux: true);
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'close', child: Text('Close tab')),
                PopupMenuItem(
                    value: 'kill',
                    child: Text('Kill tmux session')),
              ],
            ),
        ],
      ),
      body: SafeArea(child: _buildBody(tabs)),
    );
  }

  Widget _buildBody(List<TerminalSession> tabs) {
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _newTab);
    }
    if (tabs.isEmpty) {
      return Center(
        child: _busy
            ? const CircularProgressIndicator()
            : SizedBox(
                width: 220,
                child: AkariyuButton(
                  label: 'Open terminal',
                  fullWidth: true,
                  icon: Icons.terminal,
                  onPressed: _newTab,
                ),
              ),
      );
    }
    final active = tabs[_activeIndex.clamp(0, tabs.length - 1)];
    return Column(
      children: [
        if (tabs.length > 1) _TabBar(
          tabs: tabs,
          activeIndex: _activeIndex,
          onTap: (i) => setState(() => _activeIndex = i),
          onClose: (i) => _closeTab(i),
        ),
        Expanded(
          child: Container(
            color: AkariyuColors.backgroundBase,
            child: TerminalView(
              active.terminal,
              theme: _akariyuTermTheme,
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
        _KeyToolbar(
          onKey: (data) => active.terminal.textInput(data),
          onCtrl: (char) => active.terminal.keyInput(
            _ctrlKeyFor(char),
            ctrl: true,
          ),
        ),
      ],
    );
  }

  /// Maps a control-key letter to xterm's [TerminalKey] for ctrl-modified
  /// input.
  TerminalKey _ctrlKeyFor(String c) {
    switch (c.toLowerCase()) {
      case 'a':
        return TerminalKey.keyA;
      case 'c':
        return TerminalKey.keyC;
      case 'd':
        return TerminalKey.keyD;
      case 'e':
        return TerminalKey.keyE;
      case 'k':
        return TerminalKey.keyK;
      case 'l':
        return TerminalKey.keyL;
      case 'r':
        return TerminalKey.keyR;
      case 'u':
        return TerminalKey.keyU;
      case 'w':
        return TerminalKey.keyW;
      case 'z':
        return TerminalKey.keyZ;
      default:
        return TerminalKey.keyC;
    }
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.activeIndex,
    required this.onTap,
    required this.onClose,
  });

  final List<TerminalSession> tabs;
  final int activeIndex;
  final ValueChanged<int> onTap;
  final ValueChanged<int> onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: tabs.length,
        itemBuilder: (_, i) {
          final active = i == activeIndex;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Material(
              color: active
                  ? AkariyuColors.surfaceCard
                  : AkariyuColors.backgroundBase,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(
                  color: active
                      ? AkariyuColors.accent
                      : AkariyuColors.borderSubtle,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onTap(i),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(
                    children: [
                      Text(tabs[i].title,
                          style: AkariyuTypography.labelSmall.copyWith(
                            color: AkariyuColors.textPrimary,
                          )),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => onClose(i),
                        borderRadius: BorderRadius.circular(4),
                        child: Icon(Icons.close,
                            size: 12,
                            color: AkariyuColors.textTertiary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _KeyToolbar extends StatelessWidget {
  const _KeyToolbar({required this.onKey, required this.onCtrl});
  final ValueChanged<String> onKey;
  final ValueChanged<String> onCtrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AkariyuColors.surfaceElevated,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _Chip(label: 'Esc', onTap: () => onKey('\x1b')),
            _Chip(label: 'Tab', onTap: () => onKey('\t')),
            _Chip(label: '^C', onTap: () => onCtrl('c')),
            _Chip(label: '^D', onTap: () => onCtrl('d')),
            _Chip(label: '^Z', onTap: () => onCtrl('z')),
            _Chip(label: '^L', onTap: () => onCtrl('l')),
            _Chip(label: '^R', onTap: () => onCtrl('r')),
            _Chip(label: '↑', onTap: () => onKey('\x1b[A')),
            _Chip(label: '↓', onTap: () => onKey('\x1b[B')),
            _Chip(label: '←', onTap: () => onKey('\x1b[D')),
            _Chip(label: '→', onTap: () => onKey('\x1b[C')),
            _Chip(label: '|', onTap: () => onKey('|')),
            _Chip(label: '~', onTap: () => onKey('~')),
            _Chip(label: '/', onTap: () => onKey('/')),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: AkariyuColors.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: AkariyuColors.borderSubtle),
        ),
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(label,
                style: AkariyuTypography.monoSmall.copyWith(
                  color: AkariyuColors.textPrimary,
                )),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: AkariyuColors.error),
            const SizedBox(height: 12),
            Text(message,
                style: AkariyuTypography.bodyMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            SizedBox(
              width: 180,
              child: AkariyuButton(
                label: 'Retry',
                variant: AkariyuButtonVariant.secondary,
                fullWidth: true,
                onPressed: onRetry,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Color theme for the embedded xterm — tuned to match akariyu's palette.
const _akariyuTermTheme = TerminalTheme(
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
