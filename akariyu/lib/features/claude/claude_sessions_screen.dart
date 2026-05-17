import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/claude/claude_models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../shared/widgets/akariyu_card.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Lists every session (`*.jsonl`) inside one Claude project. The session
/// title is auto-generated from the first user message, mirroring
/// claude.ai's behaviour.
class ClaudeSessionsScreen extends ConsumerStatefulWidget {
  const ClaudeSessionsScreen({
    super.key,
    required this.serverId,
    required this.encodedDirName,
  });

  final String serverId;
  final String encodedDirName;

  @override
  ConsumerState<ClaudeSessionsScreen> createState() =>
      _ClaudeSessionsScreenState();
}

class _ClaudeSessionsScreenState extends ConsumerState<ClaudeSessionsScreen> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final key = ClaudeSessionsKey(
      serverId: widget.serverId,
      encodedDirName: widget.encodedDirName,
    );
    final sessions = ref.watch(claudeSessionsProvider(key));
    // Look up the cwd-enriched project from the cached projects list. If
    // we synthesise a fresh ClaudeProject here, `cwd` is null and the
    // displayPath falls back to a lossy `-` → `/` decode (which loses the
    // dot in names like `akariyu.dev`).
    final projects = ref.watch(claudeProjectsProvider(widget.serverId));
    final project = projects.maybeWhen(
          data: (list) => list
              .where((p) => p.encodedDirName == widget.encodedDirName)
              .firstOrNull,
          orElse: () => null,
        ) ??
        ClaudeProject(
          encodedDirName: widget.encodedDirName,
          absoluteDir: '',
          sessionCount: 0,
          lastModified: null,
        );
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: Text(project.displayName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(claudeSessionsProvider(key)),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(project.displayPath,
                style: AkariyuTypography.monoSmall.copyWith(fontSize: 11),
                overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
      body: SafeArea(
        child: sessions.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _Error(
            message: e.toString(),
            onRetry: () => ref.invalidate(claudeSessionsProvider(key)),
          ),
          data: (list) {
            final filtered = list.where((s) {
              if (_filter.isEmpty) return true;
              final q = _filter.toLowerCase();
              return (s.firstUserMessage ?? '')
                      .toLowerCase()
                      .contains(q) ||
                  (s.lastMessagePreview ?? '').toLowerCase().contains(q) ||
                  s.id.toLowerCase().contains(q);
            }).toList();
            return Column(
              children: [
                _SearchField(
                  onChanged: (v) => setState(() => _filter = v),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const _EmptyState()
                      : RefreshIndicator(
                          color: AkariyuColors.accent,
                          onRefresh: () async =>
                              ref.invalidate(claudeSessionsProvider(key)),
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (_, i) => _SessionTile(
                              serverId: widget.serverId,
                              session: filtered[i],
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: TextField(
        cursorColor: AkariyuColors.accent,
        style: AkariyuTypography.bodyMedium.copyWith(
          color: AkariyuColors.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: 'Search sessions',
          prefixIcon:
              Icon(Icons.search, color: AkariyuColors.textTertiary, size: 18),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.serverId, required this.session});

  final String serverId;
  final ClaudeSession session;

  String _ago(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inDays > 30) return '${(d.inDays / 30).floor()}mo';
    if (d.inDays > 0) return '${d.inDays}d';
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return 'now';
  }

  @override
  Widget build(BuildContext context) {
    return AkariyuCard(
      onTap: () => context.push(
        '/server/$serverId/claude/${Uri.encodeComponent(session.projectDir)}'
        '/sessions/${Uri.encodeComponent(session.id)}'
        '?path=${Uri.encodeQueryComponent(session.absolutePath)}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(session.title,
                    style: AkariyuTypography.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Text(_ago(session.lastMessageAt),
                  style: AkariyuTypography.labelSmall),
            ],
          ),
          if ((session.lastMessagePreview ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              session.lastMessagePreview!.replaceAll('\n', ' '),
              style: AkariyuTypography.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.forum_outlined,
                  size: 12, color: AkariyuColors.textTertiary),
              const SizedBox(width: 4),
              Text('${session.messageCount}',
                  style: AkariyuTypography.bodySmall),
              const SizedBox(width: 12),
              Icon(Icons.fingerprint,
                  size: 12, color: AkariyuColors.textTertiary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  session.id,
                  style: AkariyuTypography.monoSmall.copyWith(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
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
            Icon(Icons.forum_outlined,
                size: 48, color: AkariyuColors.textTertiary),
            const SizedBox(height: 14),
            Text('No sessions match',
                style: AkariyuTypography.headlineLarge,
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text('Try clearing the search.',
                style: AkariyuTypography.bodyMedium,
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({required this.message, required this.onRetry});
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
