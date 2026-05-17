import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/ssh/ssh_models.dart';
import '../../shared/widgets/akariyu_card.dart';
import '../../shared/widgets/status_dot.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../claude/claude_projects_screen.dart';
import '../files/file_explorer_screen.dart';
import '../terminal/terminal_screen.dart';

/// Top-level per-server scaffold: bottom-nav between Dashboard, Files,
/// Terminal. Other tabs land here when Phases 2/3 ship.
class ServerShell extends ConsumerStatefulWidget {
  const ServerShell({
    super.key,
    required this.serverId,
    this.initialTab = ServerTab.dashboard,
  });

  final String serverId;
  final ServerTab initialTab;

  @override
  ConsumerState<ServerShell> createState() => _ServerShellState();
}

enum ServerTab { dashboard, claude, files, terminal }

class _ServerShellState extends ConsumerState<ServerShell> {
  late ServerTab _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
  }

  void _go(ServerTab tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      body: IndexedStack(
        index: _tab.index,
        children: [
          _DashboardTab(serverId: widget.serverId, onGoTab: _go),
          ClaudeProjectsScreen(serverId: widget.serverId),
          FileExplorerScreen(serverId: widget.serverId),
          TerminalScreen(serverId: widget.serverId),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AkariyuColors.surfaceElevated,
        indicatorColor: AkariyuColors.accentMuted,
        selectedIndex: _tab.index,
        onDestinationSelected: (i) => _go(ServerTab.values[i]),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Claude',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Files',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Terminal',
          ),
        ],
      ),
    );
  }
}

/// Minimal per-server dashboard for Phase 1. Phase 3 replaces this with the
/// full live-metrics view (CPU/RAM/disk/processes/docker).
class _DashboardTab extends ConsumerWidget {
  const _DashboardTab({required this.serverId, required this.onGoTab});
  final String serverId;
  final ValueChanged<ServerTab> onGoTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider);
    final connState = ref.watch(connectionStateProvider(serverId));
    final mgr = ref.read(connectionManagerProvider);
    final state = connState.maybeWhen(
      data: (s) => s,
      orElse: () => mgr.stateFor(serverId),
    );
    final profile = servers.maybeWhen(
      data: (list) => list.where((p) => p.id == serverId).firstOrNull,
      orElse: () => null,
    );
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: Text(profile?.name ?? 'Server'),
      ),
      body: SafeArea(
        child: profile == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  AkariyuCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            StatusDot(status: _mapDot(state)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(profile.name,
                                  style: AkariyuTypography.titleLarge),
                            ),
                            Text(_label(state),
                                style: AkariyuTypography.bodySmall),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${profile.username}@${profile.host}:${profile.port}',
                          style: AkariyuTypography.monoSmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _QuickActions(onGoTab: onGoTab),
                  const SizedBox(height: 16),
                  AkariyuCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Coming in later phases',
                            style: AkariyuTypography.labelLarge),
                        const SizedBox(height: 12),
                        _Bullet('Claude session list & chat (Phase 2)'),
                        _Bullet('Git status / branch / commit (Phase 3)'),
                        _Bullet(
                            'Live CPU / RAM / disk / Docker dashboard (Phase 3)'),
                        _Bullet('Push notifications (Phase 4)'),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  DotStatus _mapDot(SshConnectionState s) {
    switch (s) {
      case SshConnectionState.disconnected:
        return DotStatus.idle;
      case SshConnectionState.connecting:
      case SshConnectionState.reconnecting:
        return DotStatus.connecting;
      case SshConnectionState.connected:
        return DotStatus.connected;
      case SshConnectionState.error:
        return DotStatus.error;
    }
  }

  String _label(SshConnectionState s) {
    switch (s) {
      case SshConnectionState.disconnected:
        return 'Disconnected';
      case SshConnectionState.connecting:
        return 'Connecting…';
      case SshConnectionState.reconnecting:
        return 'Reconnecting…';
      case SshConnectionState.connected:
        return 'Connected';
      case SshConnectionState.error:
        return 'Error';
    }
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 4,
              height: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AkariyuColors.textTertiary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text, style: AkariyuTypography.bodyMedium)),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onGoTab});
  final ValueChanged<ServerTab> onGoTab;

  Widget _tile(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: AkariyuCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Column(
          children: [
            Icon(icon, color: AkariyuColors.accent),
            const SizedBox(height: 8),
            Text(label,
                style: AkariyuTypography.labelSmall.copyWith(
                  color: AkariyuColors.textPrimary,
                )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _tile(Icons.chat_bubble_outline, 'Claude',
            () => onGoTab(ServerTab.claude)),
        const SizedBox(width: 12),
        _tile(Icons.folder_open, 'Files', () => onGoTab(ServerTab.files)),
        const SizedBox(width: 12),
        _tile(Icons.terminal, 'Terminal', () => onGoTab(ServerTab.terminal)),
      ],
    );
  }
}

extension _IterX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
