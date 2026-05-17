import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/ssh/ssh_models.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../shared/widgets/akariyu_card.dart';
import '../../shared/widgets/status_dot.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider);
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: const Text('akariyu'),
        actions: [
          IconButton(
            tooltip: 'Add server',
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/onboarding/add'),
          ),
        ],
      ),
      body: SafeArea(
        child: servers.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Failed to load servers: $e',
                  style: AkariyuTypography.bodyMedium),
            ),
          ),
          data: (list) {
            if (list.isEmpty) return const _EmptyState();
            return RefreshIndicator(
              color: AkariyuColors.accent,
              onRefresh: () =>
                  ref.read(serverListProvider.notifier).refresh(),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) => _ServerTile(profile: list[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined,
                color: AkariyuColors.textTertiary, size: 56),
            const SizedBox(height: 16),
            Text('No servers yet',
                style: AkariyuTypography.headlineLarge,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Add your first server to get started.',
              style: AkariyuTypography.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 220,
              child: Builder(builder: (context) {
                return AkariyuButton(
                  label: 'Add server',
                  fullWidth: true,
                  icon: Icons.add,
                  onPressed: () => context.push('/onboarding/add'),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerTile extends ConsumerStatefulWidget {
  const _ServerTile({required this.profile});
  final ServerProfile profile;

  @override
  ConsumerState<_ServerTile> createState() => _ServerTileState();
}

class _ServerTileState extends ConsumerState<_ServerTile> {
  bool _busy = false;
  String? _error;

  Future<void> _connect() async {
    HapticFeedback.lightImpact();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(connectionManagerProvider).connect(widget.profile.id);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    HapticFeedback.lightImpact();
    await ref.read(connectionManagerProvider).disconnect(widget.profile.id);
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AkariyuColors.surfaceElevated,
        title: Text('Remove ${widget.profile.name}?',
            style: AkariyuTypography.titleLarge),
        content: Text(
          'This deletes the server profile and any stored keys from this device. The server itself is untouched.',
          style: AkariyuTypography.bodyMedium,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Remove',
                  style: TextStyle(color: AkariyuColors.error))),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(serverListProvider.notifier).remove(widget.profile.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(connectionStateProvider(widget.profile.id));
    final connState = state.maybeWhen(
      data: (s) => s,
      orElse: () => ref
          .read(connectionManagerProvider)
          .stateFor(widget.profile.id),
    );
    final dot = _mapDot(connState);
    final connected = connState == SshConnectionState.connected;

    return AkariyuCard(
      onTap: connected ? null : _connect,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(status: dot),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.profile.name,
                    style: AkariyuTypography.titleLarge),
              ),
              PopupMenuButton<String>(
                color: AkariyuColors.surfaceElevated,
                icon: Icon(Icons.more_horiz,
                    color: AkariyuColors.textSecondary),
                onSelected: (v) {
                  switch (v) {
                    case 'edit':
                      context.push('/server/${widget.profile.id}/edit');
                      break;
                    case 'disconnect':
                      _disconnect();
                      break;
                    case 'delete':
                      _delete();
                      break;
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (connected)
                    const PopupMenuItem(
                        value: 'disconnect', child: Text('Disconnect')),
                  const PopupMenuItem(
                      value: 'delete', child: Text('Remove')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${widget.profile.username}@${widget.profile.host}:${widget.profile.port}',
            style: AkariyuTypography.monoSmall,
          ),
          const SizedBox(height: 4),
          Text(_labelFor(connState), style: AkariyuTypography.bodySmall),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: AkariyuTypography.bodySmall.copyWith(
                color: AkariyuColors.error,
              ),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 2),
          ],
        ],
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

  String _labelFor(SshConnectionState s) {
    switch (s) {
      case SshConnectionState.disconnected:
        return 'Tap to connect';
      case SshConnectionState.connecting:
        return 'Connecting…';
      case SshConnectionState.reconnecting:
        return 'Reconnecting…';
      case SshConnectionState.connected:
        return 'Connected';
      case SshConnectionState.error:
        return 'Connection error — tap to retry';
    }
  }
}
