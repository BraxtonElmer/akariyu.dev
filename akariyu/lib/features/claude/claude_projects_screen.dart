import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/claude/claude_models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../shared/widgets/akariyu_card.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Lists every project under `~/.claude/projects/` on the active server.
class ClaudeProjectsScreen extends ConsumerWidget {
  const ClaudeProjectsScreen({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(claudeProjectsProvider(serverId));
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: const Text('Claude'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.invalidate(claudeProjectsProvider(serverId)),
          ),
        ],
      ),
      body: SafeArea(
        child: projects.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ErrorState(
            message: e.toString(),
            onRetry: () => ref.invalidate(claudeProjectsProvider(serverId)),
          ),
          data: (list) {
            if (list.isEmpty) return const _EmptyState();
            return RefreshIndicator(
              color: AkariyuColors.accent,
              onRefresh: () async =>
                  ref.invalidate(claudeProjectsProvider(serverId)),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _ProjectTile(
                  serverId: serverId,
                  project: list[i],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({required this.serverId, required this.project});
  final String serverId;
  final ClaudeProject project;

  String _modifiedLabel() {
    final t = project.lastModified;
    if (t == null) return '—';
    final diff = DateTime.now().difference(t);
    if (diff.inDays > 30) return '${(diff.inDays / 30).floor()}mo ago';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    return AkariyuCard(
      onTap: () => context.push(
        '/server/$serverId/claude/${Uri.encodeComponent(project.encodedDirName)}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_special_outlined,
                  size: 18, color: AkariyuColors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(project.displayName,
                    style: AkariyuTypography.titleLarge),
              ),
              Text('${project.sessionCount}',
                  style: AkariyuTypography.labelSmall.copyWith(
                    color: AkariyuColors.textPrimary,
                  )),
            ],
          ),
          const SizedBox(height: 6),
          Text(project.displayPath,
              style: AkariyuTypography.monoSmall, maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(_modifiedLabel(), style: AkariyuTypography.bodySmall),
        ],
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 56, color: AkariyuColors.textTertiary),
            const SizedBox(height: 16),
            Text('No Claude projects yet',
                style: AkariyuTypography.headlineLarge,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Run `claude` inside a project on this server, then refresh.',
              style: AkariyuTypography.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
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
