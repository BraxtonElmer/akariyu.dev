import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/claude/claude_models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Read-only chat view over a parsed Claude Code session JSONL.
class ClaudeChatScreen extends ConsumerStatefulWidget {
  const ClaudeChatScreen({
    super.key,
    required this.serverId,
    required this.absolutePath,
  });

  final String serverId;
  final String absolutePath;

  @override
  ConsumerState<ClaudeChatScreen> createState() => _ClaudeChatScreenState();
}

class _ClaudeChatScreenState extends ConsumerState<ClaudeChatScreen> {
  final _scrollController = ScrollController();
  bool _autoScrolledOnce = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool jump = false}) {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (jump) {
      _scrollController.jumpTo(max);
    } else {
      _scrollController.animateTo(
        max,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = ClaudeChatKey(
      serverId: widget.serverId,
      absolutePath: widget.absolutePath,
    );
    final history = ref.watch(claudeChatHistoryProvider(key));
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: const Text('Session'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.invalidate(claudeChatHistoryProvider(key)),
          ),
        ],
      ),
      body: SafeArea(
        child: history.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _Error(
            message: e.toString(),
            onRetry: () => ref.invalidate(claudeChatHistoryProvider(key)),
          ),
          data: (messages) {
            final visible = messages
                .where((m) =>
                    m.type != 'summary' &&
                    (m.blocks.isNotEmpty || m.summary != null))
                .toList();
            if (visible.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Empty session',
                      style: AkariyuTypography.bodyMedium),
                ),
              );
            }
            if (!_autoScrolledOnce) {
              _autoScrolledOnce = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _scrollToBottom(jump: true);
              });
            }
            return Stack(
              children: [
                Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                        itemCount: visible.length,
                        itemBuilder: (_, i) => _MessageBubble(visible[i]),
                      ),
                    ),
                    _ReadOnlyBanner(),
                  ],
                ),
                Positioned(
                  right: 12,
                  bottom: 56,
                  child: _ScrollToBottomFab(
                    controller: _scrollController,
                    onTap: () => _scrollToBottom(),
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble(this.message);
  final ClaudeMessage message;

  Color _accent() {
    if (message.isAssistant) return AkariyuColors.accent;
    if (message.isUser) return AkariyuColors.info;
    return AkariyuColors.textTertiary;
  }

  IconData _icon() {
    if (message.isAssistant) return Icons.auto_awesome;
    if (message.isUser) return Icons.person_outline;
    return Icons.info_outline;
  }

  String _roleLabel() {
    if (message.isAssistant) return message.model ?? 'Claude';
    if (message.isUser) return 'You';
    return message.type;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_icon(), size: 14, color: _accent()),
              const SizedBox(width: 6),
              Text(_roleLabel(),
                  style: AkariyuTypography.labelSmall.copyWith(
                    color: _accent(),
                    fontWeight: FontWeight.w600,
                  )),
              const Spacer(),
              if (message.timestamp != null)
                Text(_formatTime(message.timestamp!),
                    style: AkariyuTypography.labelSmall),
            ],
          ),
          const SizedBox(height: 6),
          for (final block in message.blocks) _renderBlock(block),
        ],
      ),
    );
  }

  Widget _renderBlock(ClaudeBlock block) {
    return switch (block) {
      ClaudeTextBlock b => _TextBlock(text: b.text, isUser: message.isUser),
      ClaudeThinkingBlock b => _ThinkingBlock(text: b.text),
      ClaudeToolUseBlock b => _ToolUseBlock(block: b),
      ClaudeToolResultBlock b => _ToolResultBlock(block: b),
      ClaudeImageBlock b => _ImageBlock(mediaType: b.mediaType),
    };
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

class _TextBlock extends StatelessWidget {
  const _TextBlock({required this.text, required this.isUser});
  final String text;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final bg = isUser ? AkariyuColors.surfaceCard : Colors.transparent;
    final border = isUser
        ? const BorderSide(color: AkariyuColors.borderSubtle)
        : BorderSide.none;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: EdgeInsets.symmetric(
        horizontal: isUser ? 12 : 0,
        vertical: isUser ? 10 : 4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.fromBorderSide(border),
      ),
      child: MarkdownBody(
        data: text,
        selectable: true,
        onTapLink: (_, href, _) async {
          if (href != null) {
            await Clipboard.setData(ClipboardData(text: href));
          }
        },
        styleSheet: _markdownStyle(context),
      ),
    );
  }
}

class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.text});
  final String text;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: AkariyuColors.surfaceCard.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AkariyuColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined,
                      size: 14, color: AkariyuColors.textSecondary),
                  const SizedBox(width: 6),
                  Text('thinking',
                      style: AkariyuTypography.labelSmall.copyWith(
                        color: AkariyuColors.textSecondary,
                      )),
                  const Spacer(),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: AkariyuColors.textTertiary),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                widget.text,
                style: AkariyuTypography.monoSmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolUseBlock extends StatefulWidget {
  const _ToolUseBlock({required this.block});
  final ClaudeToolUseBlock block;

  @override
  State<_ToolUseBlock> createState() => _ToolUseBlockState();
}

class _ToolUseBlockState extends State<_ToolUseBlock> {
  bool _open = false;

  String _summary() {
    final input = widget.block.input;
    if (input.isEmpty) return widget.block.name;
    switch (widget.block.name) {
      case 'Bash':
        return input['command']?.toString() ?? widget.block.name;
      case 'Read':
        return input['file_path']?.toString() ?? widget.block.name;
      case 'Edit':
      case 'Write':
        return input['file_path']?.toString() ?? widget.block.name;
      case 'Glob':
        return input['pattern']?.toString() ?? widget.block.name;
      case 'Grep':
        return input['pattern']?.toString() ?? widget.block.name;
      case 'TodoWrite':
        return 'TodoWrite';
      default:
        return widget.block.name;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: AkariyuColors.surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AkariyuColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.build_circle_outlined,
                      size: 14, color: AkariyuColors.accent),
                  const SizedBox(width: 8),
                  Text(widget.block.name,
                      style: AkariyuTypography.labelSmall.copyWith(
                        color: AkariyuColors.accent,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _summary(),
                      style: AkariyuTypography.monoSmall,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: AkariyuColors.textTertiary),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(widget.block.input),
                style: AkariyuTypography.monoSmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolResultBlock extends StatefulWidget {
  const _ToolResultBlock({required this.block});
  final ClaudeToolResultBlock block;

  @override
  State<_ToolResultBlock> createState() => _ToolResultBlockState();
}

class _ToolResultBlockState extends State<_ToolResultBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.block.isError
        ? AkariyuColors.error
        : AkariyuColors.textTertiary;
    final preview = widget.block.content.split('\n').first;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: AkariyuColors.surfaceCard.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                      widget.block.isError
                          ? Icons.error_outline
                          : Icons.outbound_outlined,
                      size: 14,
                      color: color),
                  const SizedBox(width: 8),
                  Text(widget.block.isError ? 'error' : 'result',
                      style: AkariyuTypography.labelSmall.copyWith(
                        color: color,
                      )),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      preview,
                      style: AkariyuTypography.monoSmall,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: AkariyuColors.textTertiary),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                widget.block.content,
                style: AkariyuTypography.monoSmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _ImageBlock extends StatelessWidget {
  const _ImageBlock({required this.mediaType});
  final String mediaType;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AkariyuColors.surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AkariyuColors.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(Icons.image_outlined,
              size: 14, color: AkariyuColors.textSecondary),
          const SizedBox(width: 8),
          Text('Image ($mediaType)', style: AkariyuTypography.bodySmall),
        ],
      ),
    );
  }
}

/// Floating "scroll to bottom" button that appears when the user has
/// scrolled up enough to lose sight of the last message.
class _ScrollToBottomFab extends StatefulWidget {
  const _ScrollToBottomFab({required this.controller, required this.onTap});

  final ScrollController controller;
  final VoidCallback onTap;

  @override
  State<_ScrollToBottomFab> createState() => _ScrollToBottomFabState();
}

class _ScrollToBottomFabState extends State<_ScrollToBottomFab> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final pos = widget.controller.position;
    final distanceFromBottom = pos.maxScrollExtent - pos.pixels;
    final shouldShow = distanceFromBottom > 240;
    if (shouldShow != _visible) {
      setState(() => _visible = shouldShow);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: IgnorePointer(
        ignoring: !_visible,
        child: Material(
          color: AkariyuColors.surfaceCard,
          shape: const CircleBorder(
            side: BorderSide(color: AkariyuColors.borderSubtle),
          ),
          child: InkWell(
            onTap: widget.onTap,
            customBorder: const CircleBorder(),
            child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.arrow_downward,
                  size: 18, color: AkariyuColors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: AkariyuColors.surfaceElevated,
        border: Border(top: BorderSide(color: AkariyuColors.borderSubtle)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline,
              size: 14, color: AkariyuColors.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Read-only — interactive resume comes in Phase 2.2',
              style: AkariyuTypography.bodySmall,
            ),
          ),
        ],
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

MarkdownStyleSheet _markdownStyle(BuildContext context) {
  final mono = GoogleFonts.jetBrainsMono(
    fontSize: 12.5,
    height: 1.5,
    color: AkariyuColors.textPrimary,
  );
  return MarkdownStyleSheet(
    p: AkariyuTypography.bodyLarge.copyWith(height: 1.55),
    code: mono.copyWith(backgroundColor: AkariyuColors.surfaceCard),
    codeblockDecoration: BoxDecoration(
      color: AkariyuColors.surfaceCard,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AkariyuColors.borderSubtle),
    ),
    codeblockPadding: const EdgeInsets.all(12),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: AkariyuColors.accentMuted, width: 3),
      ),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12),
    h1: AkariyuTypography.displayMedium,
    h2: AkariyuTypography.headlineLarge,
    h3: AkariyuTypography.titleLarge,
    listBullet: AkariyuTypography.bodyLarge,
    a: AkariyuTypography.bodyLarge.copyWith(
      color: AkariyuColors.accent,
      decoration: TextDecoration.underline,
    ),
  );
}
