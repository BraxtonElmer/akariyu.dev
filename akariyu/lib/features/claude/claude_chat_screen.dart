import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/claude/claude_live_session.dart';
import '../../core/claude/claude_models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Read + send chat over a Claude Code session. History is sourced from
/// the on-disk `.jsonl`; live turns are appended by polling the same file
/// for mtime/size changes after we send a message via tmux.
class ClaudeChatScreen extends ConsumerStatefulWidget {
  const ClaudeChatScreen({
    super.key,
    required this.serverId,
    required this.sessionId,
    required this.absolutePath,
    required this.cwd,
  });

  final String serverId;
  final String sessionId;
  final String absolutePath;

  /// Project working directory (passed via query string). Empty when
  /// unknown — falls back to `~` on the server.
  final String cwd;

  @override
  ConsumerState<ClaudeChatScreen> createState() => _ClaudeChatScreenState();
}

class _ClaudeChatScreenState extends ConsumerState<ClaudeChatScreen> {
  final _scrollController = ScrollController();
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  bool _autoScrolledOnce = false;

  /// True once the user has sent at least one message this session — we
  /// switch from "tap to refresh" idle polling to active polling.
  bool _waiting = false;
  String? _sendError;
  Timer? _pollTimer;
  ClaudeSessionStat? _lastStat;

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.dispose();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  ClaudeLiveKey get _liveKey => ClaudeLiveKey(
        serverId: widget.serverId,
        sessionId: widget.sessionId,
        cwd: widget.cwd.isEmpty ? '~' : widget.cwd,
      );

  ClaudeChatKey get _chatKey => ClaudeChatKey(
        serverId: widget.serverId,
        absolutePath: widget.absolutePath,
      );

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

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _waiting) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _waiting = true;
      _sendError = null;
    });
    _inputController.clear();

    // Kick off a poll loop *now* so the UI shows incremental progress
    // while Claude is mid-turn (each block writes a new JSONL line). The
    // SSH command below blocks until `claude -p` exits; when it returns
    // we stop polling whether or not the file has settled.
    _lastStat = await _safeStat();
    _startPolling();

    try {
      final live = await ref.read(claudeLiveSessionProvider(_liveKey).future);
      final cfg = ref.read(claudeSendConfigProvider).valueOrNull ??
          const ClaudeSendConfig();
      final result = await live.sendMessage(text, config: cfg);
      // Final refresh, regardless of whether stat-polling already caught
      // every change.
      ref.invalidate(claudeChatHistoryProvider(_chatKey));
      _stopPolling();
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _sendError =
            'claude exit ${result.exitCode}: ${result.stdout.trim()}');
      }
    } catch (e) {
      _stopPolling();
      if (!mounted) return;
      setState(() => _sendError = e.toString());
    }
  }

  /// Light polling while a send is in flight — refresh the chat view as
  /// new JSONL lines land. Stops in [_stopPolling] when the send returns.
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      final stat = await _safeStat();
      if (stat == null || stat == _lastStat) return;
      _lastStat = stat;
      ref.invalidate(claudeChatHistoryProvider(_chatKey));
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (mounted) setState(() => _waiting = false);
  }

  Future<ClaudeSessionStat?> _safeStat() async {
    try {
      final mgr = ref.read(connectionManagerProvider);
      final conn = mgr.connectionFor(widget.serverId);
      if (conn == null) return null;
      return await statSessionFile(conn, widget.absolutePath);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openSettings() async {
    final current = ref.read(claudeSendConfigProvider).valueOrNull ??
        const ClaudeSendConfig();
    final updated = await showModalBottomSheet<ClaudeSendConfig>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AkariyuColors.surfaceElevated,
      builder: (_) => _SendConfigSheet(initial: current),
    );
    if (updated == null || updated == current) return;
    await ref.read(claudeSendConfigProvider.notifier).save(updated);
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(claudeChatHistoryProvider(_chatKey));
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: const _ChatTitle(),
        actions: [
          IconButton(
            tooltip: 'Send settings',
            icon: const Icon(Icons.tune),
            onPressed: _openSettings,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.invalidate(claudeChatHistoryProvider(_chatKey)),
          ),
        ],
      ),
      body: SafeArea(
        child: history.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _Error(
            message: e.toString(),
            onRetry: () => ref.invalidate(claudeChatHistoryProvider(_chatKey)),
          ),
          data: (messages) {
            final visible = messages
                .where((m) =>
                    m.type != 'summary' && m.blocks.isNotEmpty)
                .toList();
            if (!_autoScrolledOnce && visible.isNotEmpty) {
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
                      child: visible.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text('Empty session — say hi.',
                                    style: AkariyuTypography.bodyMedium),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                              itemCount: visible.length,
                              itemBuilder: (_, i) =>
                                  _MessageBubble(visible[i]),
                            ),
                    ),
                    if (_sendError != null)
                      _SendErrorBanner(
                        message: _sendError!,
                        onDismiss: () => setState(() => _sendError = null),
                      ),
                    _InputBar(
                      controller: _inputController,
                      focusNode: _inputFocus,
                      busy: _waiting,
                      onSend: _send,
                    ),
                  ],
                ),
                Positioned(
                  right: 12,
                  bottom: 100,
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

/// Two-line title in the chat app bar: "Session" + current model /
/// permission mode summary.
class _ChatTitle extends ConsumerWidget {
  const _ChatTitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(claudeSendConfigProvider).valueOrNull ??
        const ClaudeSendConfig();
    final summary = [
      cfg.model,
      if (cfg.permissionMode != 'default') cfg.permissionMode,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Session'),
        const SizedBox(height: 2),
        Text(summary,
            style: AkariyuTypography.labelSmall.copyWith(
              color: AkariyuColors.textTertiary,
            )),
      ],
    );
  }
}

/// Bottom-sheet picker for model + permission mode. Returns the new
/// [ClaudeSendConfig] when the user taps Save, or `null` on dismiss.
class _SendConfigSheet extends StatefulWidget {
  const _SendConfigSheet({required this.initial});
  final ClaudeSendConfig initial;

  @override
  State<_SendConfigSheet> createState() => _SendConfigSheetState();
}

class _SendConfigSheetState extends State<_SendConfigSheet> {
  late String _model = widget.initial.model;
  late String _permissionMode = widget.initial.permissionMode;

  static const _models = <_Choice>[
    _Choice('default', 'Default', 'Whatever ~/.claude/settings.json says'),
    _Choice('opus', 'Opus', 'Most capable, slowest'),
    _Choice('sonnet', 'Sonnet', 'Balanced default'),
    _Choice('haiku', 'Haiku', 'Fastest, lightest'),
  ];

  static const _modes = <_Choice>[
    _Choice('default', 'Default', 'Prompt for each tool use'),
    _Choice('acceptEdits', 'Accept edits',
        'Auto-allow file edits; still prompt for shell'),
    _Choice('plan', 'Plan', 'Plan-only mode, no tools execute'),
    _Choice(
        'bypassPermissions', 'Bypass', 'Skip every prompt — be careful'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AkariyuColors.borderSubtle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Send settings', style: AkariyuTypography.headlineLarge),
            const SizedBox(height: 4),
            Text(
              'Applied to every message you send from this device.',
              style: AkariyuTypography.bodySmall,
            ),
            const SizedBox(height: 20),
            Text('Model',
                style: AkariyuTypography.labelLarge.copyWith(
                  color: AkariyuColors.textSecondary,
                )),
            const SizedBox(height: 8),
            _ChoiceList(
              choices: _models,
              value: _model,
              onChanged: (v) => setState(() => _model = v),
            ),
            const SizedBox(height: 20),
            Text('Permission mode',
                style: AkariyuTypography.labelLarge.copyWith(
                  color: AkariyuColors.textSecondary,
                )),
            const SizedBox(height: 8),
            _ChoiceList(
              choices: _modes,
              value: _permissionMode,
              onChanged: (v) => setState(() => _permissionMode = v),
            ),
            const SizedBox(height: 20),
            AkariyuButton(
              label: 'Save',
              fullWidth: true,
              onPressed: () => Navigator.of(context).pop(
                ClaudeSendConfig(
                  model: _model,
                  permissionMode: _permissionMode,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice {
  const _Choice(this.value, this.label, this.description);
  final String value;
  final String label;
  final String description;
}

class _ChoiceList extends StatelessWidget {
  const _ChoiceList({
    required this.choices,
    required this.value,
    required this.onChanged,
  });
  final List<_Choice> choices;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AkariyuColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AkariyuColors.borderSubtle),
      ),
      child: Column(
        children: [
          for (var i = 0; i < choices.length; i++) ...[
            if (i > 0)
              const Divider(height: 1, color: AkariyuColors.borderSubtle),
            InkWell(
              onTap: () => onChanged(choices[i].value),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(choices[i].label,
                              style: AkariyuTypography.bodyLarge),
                          const SizedBox(height: 2),
                          Text(choices[i].description,
                              style: AkariyuTypography.bodySmall),
                        ],
                      ),
                    ),
                    if (value == choices[i].value)
                      Icon(Icons.check_circle,
                          color: AkariyuColors.accent, size: 18)
                    else
                      Icon(Icons.radio_button_unchecked,
                          color: AkariyuColors.textTertiary, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: AkariyuColors.backgroundBase,
        border: Border(top: BorderSide(color: AkariyuColors.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const _WorkingChip(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AkariyuColors.surfaceCard,
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: AkariyuColors.borderSubtle),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 6,
                    cursorColor: AkariyuColors.accent,
                    style: AkariyuTypography.bodyLarge,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: 'Message Claude…',
                      hintStyle: AkariyuTypography.bodyMedium.copyWith(
                        color: AkariyuColors.textTertiary,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SendButton(busy: busy, onTap: onSend),
            ],
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: busy ? AkariyuColors.surfaceCard : AkariyuColors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: busy ? null : onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AkariyuColors.textPrimary,
                  ),
                )
              : const Icon(Icons.arrow_upward,
                  size: 20, color: AkariyuColors.textPrimary),
        ),
      ),
    );
  }
}

class _WorkingChip extends StatelessWidget {
  const _WorkingChip();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AkariyuColors.surfaceCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AkariyuColors.borderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AkariyuColors.accent,
                ),
              ),
              const SizedBox(width: 8),
              Text('Claude is working…',
                  style: AkariyuTypography.labelSmall.copyWith(
                    color: AkariyuColors.textSecondary,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendErrorBanner extends StatelessWidget {
  const _SendErrorBanner({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AkariyuColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AkariyuColors.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              size: 16, color: AkariyuColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: AkariyuTypography.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: Icon(Icons.close,
                size: 14, color: AkariyuColors.textTertiary),
            visualDensity: VisualDensity.compact,
          ),
        ],
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
      case 'Edit':
      case 'Write':
        return input['file_path']?.toString() ?? widget.block.name;
      case 'Glob':
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
