import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/claude/claude_live_session.dart';
import '../../core/claude/claude_models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../shared/widgets/akariyu_text_field.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../files/file_explorer_screen.dart';
import 'claude_login_screen.dart';

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

  /// Files queued to be prepended as `@<path>` mentions in the next
  /// send. Render as preview chips above the input.
  final List<_PendingAttachment> _attachments = [];

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

  Future<void> _send({String? overrideText}) async {
    final body = (overrideText ?? _inputController.text).trim();
    // Send is gated on either text OR attachments — image-only sends
    // are valid.
    if (body.isEmpty && _attachments.isEmpty || _waiting) return;
    HapticFeedback.mediumImpact();

    // Build the final prompt: `@/path/one @/path/two\n<body>`.
    // Claude Code's CLI expands @-references natively (file contents,
    // images, …) so this is all we have to do.
    final mentions = _attachments.map((a) => '@${a.path}').join(' ');
    final composed = mentions.isEmpty
        ? body
        : (body.isEmpty ? mentions : '$mentions\n\n$body');

    setState(() {
      _waiting = true;
      _sendError = null;
      _attachments.clear();
    });
    if (overrideText == null) _inputController.clear();

    _lastStat = await _safeStat();
    _startPolling();

    try {
      final live = await ref.read(claudeLiveSessionProvider(_liveKey).future);
      final cfg = ref.read(claudeSendConfigProvider).valueOrNull ??
          const ClaudeSendConfig();
      final result = await live.sendMessage(composed, config: cfg);
      ref.invalidate(claudeChatHistoryProvider(_chatKey));
      _stopPolling();
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _sendError =
            'claude exit ${result.exitCode}: ${result.stdout.trim()}');
      }
    } on ClaudeNotInstalledException {
      _stopPolling();
      if (!mounted) return;
      // Offer to install, then retry with the composed prompt (mentions
      // + body) so attachments aren't lost.
      final installed = await _promptInstall();
      if (installed && mounted) {
        await _send(overrideText: composed);
      }
    } on ClaudeNotAuthenticatedException {
      _stopPolling();
      if (!mounted) return;
      final authed = await _promptApiKey();
      if (authed && mounted) {
        await _send(overrideText: composed);
      }
    } catch (e) {
      _stopPolling();
      if (!mounted) return;
      setState(() => _sendError = e.toString());
    }
  }

  /// Bottom sheet that offers two ways to authenticate Claude on the
  /// server. Returns true on success so the caller can retry the send.
  Future<bool> _promptApiKey() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AkariyuColors.surfaceElevated,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
              Text('Authenticate Claude Code',
                  style: AkariyuTypography.headlineLarge),
              const SizedBox(height: 4),
              Text(
                'Pick how you want to log in. Both store credentials on '
                'the server, not on this device.',
                style: AkariyuTypography.bodySmall,
              ),
              const SizedBox(height: 20),
              _AuthOptionTile(
                icon: Icons.account_circle_outlined,
                label: 'Log in with Anthropic account',
                detail:
                    'Browser OAuth via `claude /login`. Best for Claude '
                    'Pro / Max subscribers.',
                onTap: () => Navigator.pop(ctx, 'oauth'),
              ),
              const SizedBox(height: 10),
              _AuthOptionTile(
                icon: Icons.vpn_key_outlined,
                label: 'Paste API key',
                detail:
                    'From console.anthropic.com/settings/keys. Saved to '
                    '~/.claude/akariyu.env (chmod 600).',
                onTap: () => Navigator.pop(ctx, 'apikey'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == 'apikey') return _promptApiKeyEntry();
    if (choice == 'oauth') return _runOAuthLogin();
    return false;
  }

  Future<bool> _promptApiKeyEntry() async {
    final ctrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AkariyuColors.surfaceElevated,
        title: Text('Paste Anthropic API key',
            style: AkariyuTypography.titleLarge),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Get a key at console.anthropic.com/settings/keys. '
                'Stored on the server in ~/.claude/akariyu.env (chmod 600).',
                style: AkariyuTypography.bodyMedium,
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async => Clipboard.setData(const ClipboardData(
                    text: 'https://console.anthropic.com/settings/keys')),
                child: Text(
                  'Tap to copy link',
                  style: AkariyuTypography.bodySmall.copyWith(
                    color: AkariyuColors.accent,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                autofocus: true,
                obscureText: true,
                cursorColor: AkariyuColors.accent,
                style: AkariyuTypography.mono,
                decoration: const InputDecoration(hintText: 'sk-ant-…'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Save',
                style: TextStyle(color: AkariyuColors.accent)),
          ),
        ],
      ),
    );
    if (saved != true || ctrl.text.trim().isEmpty) {
      ctrl.dispose();
      return false;
    }
    try {
      final live = await ref.read(claudeLiveSessionProvider(_liveKey).future);
      await live.setApiKey(ctrl.text.trim());
      ctrl.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('API key saved')),
        );
      }
      return true;
    } catch (e) {
      ctrl.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
      return false;
    }
  }

  /// OAuth flow: navigate to a full-screen terminal pre-running
  /// `claude /login`. The user completes the TUI auth interactively and
  /// taps "Done" to return — we then retry their pending message.
  Future<bool> _runOAuthLogin() async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ClaudeLoginScreen(serverId: widget.serverId),
        fullscreenDialog: true,
      ),
    );
    return done == true;
  }

  /// Shows an install-claude dialog. Returns true on a successful install.
  Future<bool> _promptInstall() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AkariyuColors.surfaceElevated,
        title: Text('Install Claude Code?',
            style: AkariyuTypography.titleLarge),
        content: Text(
          'Claude Code (`claude` CLI) wasn\'t found in your server\'s PATH. '
          'Install it now via `npm install -g @anthropic-ai/claude-code`?',
          style: AkariyuTypography.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Install',
                style: TextStyle(color: AkariyuColors.accent)),
          ),
        ],
      ),
    );
    if (confirm != true) return false;
    return _runInstall();
  }

  Future<bool> _runInstall() async {
    final controller = ValueNotifier<_InstallProgress>(
      const _InstallProgress(running: true, tail: 'Starting install…'),
    );
    final buf = StringBuffer();
    void append(String chunk) {
      buf.write(chunk);
      // Keep only the last ~8 KB so the dialog doesn't grow unbounded
      // for nvm's noisy curl + npm output.
      final s = buf.toString();
      final tail = s.length > 8192 ? s.substring(s.length - 8192) : s;
      controller.value = _InstallProgress(running: true, tail: tail);
    }

    // Fire the install + plumb the result back to the dialog.
    () async {
      try {
        final live =
            await ref.read(claudeLiveSessionProvider(_liveKey).future);
        final res = await live.installClaude(onChunk: append);
        controller.value = _InstallProgress(
          running: false,
          tail: buf.toString(),
          ok: res.ok,
          error: res.ok ? null : 'install exit ${res.exitCode}',
        );
      } catch (e) {
        controller.value = _InstallProgress(
          running: false,
          tail: buf.isEmpty ? e.toString() : buf.toString(),
          ok: false,
          error: e.toString(),
        );
      }
    }();

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<_InstallProgress>(
        valueListenable: controller,
        builder: (ctx, p, _) => AlertDialog(
          backgroundColor: AkariyuColors.surfaceElevated,
          title: Text(
            p.running
                ? 'Installing Claude Code…'
                : p.ok
                    ? 'Install succeeded'
                    : 'Install failed',
            style: AkariyuTypography.titleLarge,
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.running) const LinearProgressIndicator(minHeight: 2),
                if (p.running) const SizedBox(height: 12),
                Container(
                  height: 160,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AkariyuColors.surfaceCard,
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: AkariyuColors.borderSubtle),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      p.tail.isEmpty ? ' ' : p.tail,
                      style: AkariyuTypography.monoSmall
                          .copyWith(fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (!p.running)
              TextButton(
                onPressed: () => Navigator.pop(ctx, p.ok),
                child: const Text('Close'),
              ),
          ],
        ),
      ),
    );
    // Defer the notifier disposal a frame past dialog dismissal — the
    // ValueListenableBuilder needs to unsubscribe BEFORE we tear the
    // notifier down, otherwise Flutter trips `_dependents.isEmpty`.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    return ok == true;
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

  /// Bottom-sheet picker for adding an `@<path>` reference to the input.
  /// Camera/gallery/device-file → upload to server then mention. Server
  /// path → just mention it directly.
  Future<void> _openAttachSheet() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AkariyuColors.surfaceElevated,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
              Text('Attach',
                  style: AkariyuTypography.headlineLarge),
              const SizedBox(height: 4),
              Text(
                'Files are uploaded to ~/.claude/akariyu-uploads/ on the '
                'server and referenced as @<path> in your message — '
                'Claude reads them natively.',
                style: AkariyuTypography.bodySmall,
              ),
              const SizedBox(height: 20),
              _AuthOptionTile(
                icon: Icons.photo_camera_outlined,
                label: 'Take photo',
                detail: 'Open the camera and attach the shot.',
                onTap: () => Navigator.pop(ctx, 'camera'),
              ),
              const SizedBox(height: 10),
              _AuthOptionTile(
                icon: Icons.photo_library_outlined,
                label: 'Photo from gallery',
                detail: 'Pick an image from your device.',
                onTap: () => Navigator.pop(ctx, 'gallery'),
              ),
              const SizedBox(height: 10),
              _AuthOptionTile(
                icon: Icons.attach_file_outlined,
                label: 'File from device',
                detail: 'Any file from your phone storage.',
                onTap: () => Navigator.pop(ctx, 'device'),
              ),
              const SizedBox(height: 10),
              _AuthOptionTile(
                icon: Icons.dns_outlined,
                label: 'File on server',
                detail:
                    'Reference an existing path. Use the Files tab to '
                    'browse + copy path.',
                onTap: () => Navigator.pop(ctx, 'server'),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;
    switch (source) {
      case 'camera':
        await _attachFromImagePicker(ImageSource.camera);
        break;
      case 'gallery':
        await _attachFromImagePicker(ImageSource.gallery);
        break;
      case 'device':
        await _attachFromDeviceFile();
        break;
      case 'server':
        await _attachFromServerPath();
        break;
    }
  }

  Future<void> _attachFromImagePicker(ImageSource src) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await ImagePicker().pickImage(
        source: src,
        imageQuality: 88,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _uploadAndMention(bytes: bytes, fileName: picked.name);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Attach failed: $e')));
    }
  }

  Future<void> _attachFromDeviceFile() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        allowMultiple: false,
      );
      final file = result?.files.firstOrNull;
      if (file == null) return;
      final bytes = file.bytes;
      if (bytes == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not read file bytes')),
        );
        return;
      }
      await _uploadAndMention(bytes: bytes, fileName: file.name);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Attach failed: $e')));
    }
  }

  /// Push the file explorer in picker mode, starting from the project's
  /// cwd if known. Tapping a file pops back with its absolute path.
  Future<void> _attachFromServerPath() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FileExplorerScreen(
          serverId: widget.serverId,
          initialPath: widget.cwd.isEmpty ? null : widget.cwd,
          pickerMode: true,
        ),
        fullscreenDialog: true,
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _attachments.add(_PendingAttachment(
          path: picked,
          displayName: picked.split('/').last,
          isImage: _looksLikeImage(picked),
          thumbnail: null,
        )));
  }

  Future<void> _uploadAndMention({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final overlay = _showUploadingSnack(messenger, fileName);
    try {
      final live = await ref.read(claudeLiveSessionProvider(_liveKey).future);
      final remotePath =
          await live.uploadAttachment(bytes: bytes, fileName: fileName);
      overlay.close();
      if (!mounted) return;
      final isImage = _looksLikeImage(fileName);
      setState(() => _attachments.add(_PendingAttachment(
            path: remotePath,
            displayName: fileName,
            isImage: isImage,
            // Keep a thumbnail-sized copy in memory only for images so
            // we can render a chip preview; larger files would balloon
            // the heap.
            thumbnail: (isImage && bytes.length < 4 * 1024 * 1024)
                ? bytes
                : null,
          )));
    } catch (e) {
      overlay.close();
      messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  ScaffoldFeatureController _showUploadingSnack(
    ScaffoldMessengerState messenger,
    String fileName,
  ) {
    return messenger.showSnackBar(SnackBar(
      duration: const Duration(minutes: 5),
      content: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child:
                CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text('Uploading $fileName…')),
        ],
      ),
    ));
  }

  void _removeAttachment(_PendingAttachment a) {
    setState(() => _attachments.remove(a));
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
                              // Caching ~3 screens of bubbles keeps
                              // scroll jank away on long sessions.
                              cacheExtent: 1200,
                              // Each bubble re-renders markdown +
                              // collapsible tool cards; isolate them in
                              // their own layer so unrelated state
                              // (polling tick, input typing) doesn't
                              // force the whole list to repaint.
                              itemBuilder: (_, i) => RepaintBoundary(
                                key: ValueKey(visible[i].uuid ?? i),
                                child: _MessageBubble(visible[i]),
                              ),
                            ),
                    ),
                    if (_sendError != null)
                      _SendErrorBanner(
                        message: _sendError!,
                        onDismiss: () => setState(() => _sendError = null),
                      ),
                    if (_attachments.isNotEmpty)
                      _AttachmentStrip(
                        attachments: _attachments,
                        onRemove: _removeAttachment,
                      ),
                    _InputBar(
                      controller: _inputController,
                      focusNode: _inputFocus,
                      busy: _waiting,
                      onSend: _send,
                      onAttach: _openAttachSheet,
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


/// One row in the "how do you want to authenticate?" bottom sheet.
class _AuthOptionTile extends StatelessWidget {
  const _AuthOptionTile({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AkariyuColors.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AkariyuColors.borderSubtle),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: AkariyuColors.accent, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AkariyuTypography.bodyLarge),
                    const SizedBox(height: 2),
                    Text(detail, style: AkariyuTypography.bodySmall),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: AkariyuColors.textTertiary, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// Snapshot of an in-flight `npm install -g …` for the install dialog.
/// Horizontal strip of pending-attachment chips, shown above the input
/// bar. Each chip is a thumbnail (for images) or an icon + filename
/// (for everything else), with a small `×` to remove.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.attachments,
    required this.onRemove,
  });

  final List<_PendingAttachment> attachments;
  final ValueChanged<_PendingAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => _AttachmentChip(
          attachment: attachments[i],
          onRemove: () => onRemove(attachments[i]),
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment, required this.onRemove});

  final _PendingAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    return RepaintBoundary(
      child: SizedBox(
        width: 60,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: AkariyuColors.surfaceCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AkariyuColors.borderSubtle),
              ),
              clipBehavior: Clip.antiAlias,
              child: a.isImage && a.thumbnail != null
                  ? Image.memory(a.thumbnail!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.low)
                  : Center(
                      child: Icon(
                        a.isImage
                            ? Icons.image_outlined
                            : Icons.insert_drive_file_outlined,
                        size: 22,
                        color: AkariyuColors.textSecondary,
                      ),
                    ),
            ),
            Positioned(
              right: -6,
              top: -6,
              child: Material(
                color: AkariyuColors.backgroundBase,
                shape: const CircleBorder(
                  side: BorderSide(color: AkariyuColors.borderSubtle),
                ),
                child: InkWell(
                  onTap: onRemove,
                  customBorder: const CircleBorder(),
                  child: const SizedBox(
                    width: 22,
                    height: 22,
                    child: Icon(Icons.close,
                        size: 12, color: AkariyuColors.textSecondary),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 2,
              right: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  a.displayName,
                  style: AkariyuTypography.labelSmall.copyWith(
                    color: AkariyuColors.textPrimary,
                    fontSize: 9,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A file queued for prepending as `@<path>` in the next send. Rendered
/// as a chip above the input bar — image attachments carry a thumbnail
/// so we can show a real preview.
class _PendingAttachment {
  const _PendingAttachment({
    required this.path,
    required this.displayName,
    required this.isImage,
    required this.thumbnail,
  });

  final String path;
  final String displayName;
  final bool isImage;
  final Uint8List? thumbnail;
}

bool _looksLikeImage(String path) {
  final ext = path.toLowerCase();
  return ext.endsWith('.png') ||
      ext.endsWith('.jpg') ||
      ext.endsWith('.jpeg') ||
      ext.endsWith('.gif') ||
      ext.endsWith('.webp') ||
      ext.endsWith('.bmp') ||
      ext.endsWith('.heic');
}

class _InstallProgress {
  const _InstallProgress({
    required this.running,
    required this.tail,
    this.ok = false,
    this.error,
  });

  final bool running;
  final String tail;
  final bool ok;
  final String? error;
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
  late final _maxTurnsCtrl = TextEditingController(
    text: widget.initial.maxTurns?.toString() ?? '',
  );
  late final _appendCtrl = TextEditingController(
    text: widget.initial.appendSystemPrompt,
  );
  late bool _verbose = widget.initial.verbose;
  late final _allowedCtrl =
      TextEditingController(text: widget.initial.allowedTools);
  late final _disallowedCtrl =
      TextEditingController(text: widget.initial.disallowedTools);
  late final _addDirsCtrl =
      TextEditingController(text: widget.initial.addDirs);
  late final _mcpCtrl =
      TextEditingController(text: widget.initial.mcpConfig);
  late bool _strictMcp = widget.initial.strictMcpConfig;
  late bool _skipPerms = widget.initial.dangerouslySkipPermissions;
  late final _settingsPathCtrl =
      TextEditingController(text: widget.initial.settingsPath);
  late final _rawArgsCtrl =
      TextEditingController(text: widget.initial.rawExtraArgs);

  @override
  void dispose() {
    _maxTurnsCtrl.dispose();
    _appendCtrl.dispose();
    _allowedCtrl.dispose();
    _disallowedCtrl.dispose();
    _addDirsCtrl.dispose();
    _mcpCtrl.dispose();
    _settingsPathCtrl.dispose();
    _rawArgsCtrl.dispose();
    super.dispose();
  }

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

  ClaudeSendConfig _build() {
    final raw = _maxTurnsCtrl.text.trim();
    final parsed = raw.isEmpty ? null : int.tryParse(raw);
    return ClaudeSendConfig(
      model: _model,
      permissionMode: _permissionMode,
      maxTurns: parsed,
      appendSystemPrompt: _appendCtrl.text.trim(),
      verbose: _verbose,
      allowedTools: _allowedCtrl.text.trim(),
      disallowedTools: _disallowedCtrl.text.trim(),
      addDirs: _addDirsCtrl.text.trim(),
      mcpConfig: _mcpCtrl.text.trim(),
      strictMcpConfig: _strictMcp,
      dangerouslySkipPermissions: _skipPerms,
      settingsPath: _settingsPathCtrl.text.trim(),
      rawExtraArgs: _rawArgsCtrl.text.trim(),
    );
  }

  Widget _sectionLabel(String text) => Text(text,
      style: AkariyuTypography.labelLarge.copyWith(
        color: AkariyuColors.textSecondary,
      ));

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomInset),
        child: SingleChildScrollView(
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
              _sectionLabel('Model'),
              const SizedBox(height: 8),
              _ChoiceList(
                choices: _models,
                value: _model,
                onChanged: (v) => setState(() => _model = v),
              ),
              const SizedBox(height: 20),
              _sectionLabel('Permission mode'),
              const SizedBox(height: 8),
              _ChoiceList(
                choices: _modes,
                value: _permissionMode,
                onChanged: (v) => setState(() => _permissionMode = v),
              ),
              const SizedBox(height: 20),
              _sectionLabel('Max turns'),
              const SizedBox(height: 8),
              AkariyuTextField(
                controller: _maxTurnsCtrl,
                hint: 'unlimited',
                helper: 'Cap on conversation turns per send. Blank = no cap.',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 20),
              _sectionLabel('Append to system prompt'),
              const SizedBox(height: 8),
              AkariyuTextField(
                controller: _appendCtrl,
                hint: 'Extra instructions for Claude',
                helper: 'Sent via --append-system-prompt every message.',
                minLines: 2,
                maxLines: 5,
              ),
              const SizedBox(height: 20),
              SwitchListTile.adaptive(
                value: _verbose,
                onChanged: (v) => setState(() => _verbose = v),
                title:
                    Text('Verbose', style: AkariyuTypography.bodyLarge),
                subtitle: Text(
                  'Pass --verbose to Claude. More noise, more detail.',
                  style: AkariyuTypography.bodySmall,
                ),
                activeThumbColor: AkariyuColors.accent,
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile.adaptive(
                value: _skipPerms,
                onChanged: (v) => setState(() => _skipPerms = v),
                title: Text('Dangerously skip permissions',
                    style: AkariyuTypography.bodyLarge),
                subtitle: Text(
                  '--dangerously-skip-permissions. Equivalent to bypass '
                  'mode. Don\'t use this on production servers.',
                  style: AkariyuTypography.bodySmall,
                ),
                activeThumbColor: AkariyuColors.error,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              _sectionLabel('Allowed tools'),
              const SizedBox(height: 8),
              AkariyuTextField(
                controller: _allowedCtrl,
                hint: 'Read,Bash,Edit',
                helper: 'Comma-separated. Blank = Claude decides.',
              ),
              const SizedBox(height: 16),
              _sectionLabel('Disallowed tools'),
              const SizedBox(height: 8),
              AkariyuTextField(
                controller: _disallowedCtrl,
                hint: 'Bash,Write',
                helper: 'Tools Claude must never use.',
              ),
              const SizedBox(height: 16),
              _sectionLabel('Additional directories'),
              const SizedBox(height: 8),
              AkariyuTextField(
                controller: _addDirsCtrl,
                hint: '/home/me/other-project, /tmp/scratch',
                helper:
                    'Comma-separated absolute paths. Each becomes --add-dir.',
              ),
              const SizedBox(height: 16),
              _sectionLabel('MCP config'),
              const SizedBox(height: 8),
              AkariyuTextField(
                controller: _mcpCtrl,
                hint: '/home/me/.claude/mcp.json',
                helper: 'Path to MCP servers config. Blank = use default.',
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                value: _strictMcp,
                onChanged: (v) => setState(() => _strictMcp = v),
                title: Text('Strict MCP', style: AkariyuTypography.bodyLarge),
                subtitle: Text(
                  '--strict-mcp-config. Fail send if any MCP server in '
                  'the config can\'t start.',
                  style: AkariyuTypography.bodySmall,
                ),
                activeThumbColor: AkariyuColors.accent,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              _sectionLabel('settings.json path'),
              const SizedBox(height: 8),
              AkariyuTextField(
                controller: _settingsPathCtrl,
                hint: '~/.claude/settings.json',
                helper: 'Override the settings.json claude reads. Blank '
                    '= default.',
              ),
              const SizedBox(height: 16),
              _sectionLabel('Raw extra args'),
              const SizedBox(height: 8),
              AkariyuTextField(
                controller: _rawArgsCtrl,
                hint: '--input-format text --output-format text',
                helper: 'Appended verbatim to the claude command. Use for '
                    'anything not covered above. You quote it yourself.',
                minLines: 1,
                maxLines: 3,
                monospace: true,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AkariyuColors.surfaceCard.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: AkariyuColors.borderSubtle),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: AkariyuColors.textTertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'For knobs that aren\'t CLI flags — thinking '
                        'budget, env vars, model aliases — edit your '
                        'server\'s ~/.claude/settings.json directly via '
                        'the Files tab.',
                        style: AkariyuTypography.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AkariyuButton(
                label: 'Save',
                fullWidth: true,
                onPressed: () => Navigator.of(context).pop(_build()),
              ),
            ],
          ),
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
    required this.onAttach,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onAttach;

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
              _AttachButton(onTap: busy ? null : onAttach),
              const SizedBox(width: 6),
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

class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AkariyuColors.surfaceCard,
      shape: const CircleBorder(
        side: BorderSide(color: AkariyuColors.borderSubtle),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            Icons.add,
            size: 22,
            color: onTap == null
                ? AkariyuColors.textTertiary
                : AkariyuColors.textPrimary,
          ),
        ),
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
