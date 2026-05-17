import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;

import '../../core/providers.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Read/edit a remote text file via SFTP. Read-only by default; tap the
/// edit toggle to enable editing.
class FileEditorScreen extends ConsumerStatefulWidget {
  const FileEditorScreen({
    super.key,
    required this.serverId,
    required this.path,
  });

  final String serverId;
  final String path;

  @override
  ConsumerState<FileEditorScreen> createState() => _FileEditorScreenState();
}

class _FileEditorScreenState extends ConsumerState<FileEditorScreen> {
  late final TextEditingController _controller;
  late final ScrollController _scroll;
  String _original = '';
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  bool _wrap = false;
  double _fontSize = 13;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _scroll = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sftp = await ref.read(sftpServiceProvider(widget.serverId).future);
      final text = await sftp.readText(widget.path);
      if (!mounted) return;
      setState(() {
        _original = text;
        _controller.text = text;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_controller.text == _original) {
      setState(() => _editing = false);
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);
    try {
      final sftp = await ref.read(sftpServiceProvider(widget.serverId).future);
      await sftp.writeText(widget.path, _controller.text);
      if (!mounted) return;
      setState(() {
        _original = _controller.text;
        _editing = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  String? _language() {
    final ext = p.extension(widget.path).toLowerCase();
    return switch (ext) {
      '.dart' => 'dart',
      '.js' || '.mjs' || '.cjs' => 'javascript',
      '.ts' => 'typescript',
      '.tsx' => 'typescript',
      '.py' => 'python',
      '.go' => 'go',
      '.rs' => 'rust',
      '.java' => 'java',
      '.kt' || '.kts' => 'kotlin',
      '.swift' => 'swift',
      '.c' || '.h' => 'c',
      '.cpp' || '.hpp' || '.cc' || '.hh' => 'cpp',
      '.rb' => 'ruby',
      '.php' => 'php',
      '.sh' || '.bash' || '.zsh' => 'bash',
      '.json' => 'json',
      '.yaml' || '.yml' => 'yaml',
      '.toml' => 'ini',
      '.html' || '.htm' => 'xml',
      '.css' => 'css',
      '.md' || '.markdown' => 'markdown',
      '.sql' => 'sql',
      '.xml' => 'xml',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final dirty = _editing && _controller.text != _original;
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !dirty) return;
        final navigator = Navigator.of(context);
        final ok = await _confirmDiscard();
        if (!ok) return;
        navigator.pop();
      },
      child: Scaffold(
        backgroundColor: AkariyuColors.backgroundBase,
        appBar: AppBar(
          title: Text(
            p.basename(widget.path),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: _wrap ? 'Disable word wrap' : 'Word wrap',
              icon: Icon(_wrap ? Icons.wrap_text : Icons.short_text),
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
            PopupMenuButton<String>(
              color: AkariyuColors.surfaceElevated,
              icon: const Icon(Icons.text_fields),
              onSelected: (v) => setState(() => _fontSize = double.parse(v)),
              itemBuilder: (_) => [
                for (final s in [11.0, 12.0, 13.0, 14.0, 15.0, 16.0])
                  PopupMenuItem(
                    value: s.toString(),
                    child: Text('${s.toInt()} pt'),
                  ),
              ],
            ),
            if (_editing)
              IconButton(
                tooltip: 'Save',
                icon: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.check,
                        color: dirty
                            ? AkariyuColors.accent
                            : AkariyuColors.textTertiary),
                onPressed: _saving ? null : _save,
              )
            else
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _loading || _error != null
                    ? null
                    : () => setState(() => _editing = true),
              ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(20),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Icon(
                    _editing
                        ? Icons.edit_note
                        : Icons.lock_outline,
                    size: 12,
                    color: AkariyuColors.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.path,
                      style: AkariyuTypography.monoSmall
                          .copyWith(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (dirty)
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AkariyuColors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _ErrorView(message: _error!, onRetry: _load);
    return _editing ? _buildEditor() : _buildViewer();
  }

  Widget _buildViewer() {
    final lang = _language();
    final textStyle = GoogleFonts.jetBrainsMono(
      fontSize: _fontSize,
      height: 1.5,
      color: AkariyuColors.textPrimary,
    );
    final view = HighlightView(
      _original,
      language: lang ?? 'plaintext',
      theme: atomOneDarkTheme,
      textStyle: textStyle,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
    );
    if (_wrap) {
      return SingleChildScrollView(
        controller: _scroll,
        child: view,
      );
    }
    return SingleChildScrollView(
      controller: _scroll,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: view,
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: TextField(
        controller: _controller,
        maxLines: null,
        expands: true,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        cursorColor: AkariyuColors.accent,
        autocorrect: false,
        enableSuggestions: false,
        style: GoogleFonts.jetBrainsMono(
          fontSize: _fontSize,
          height: 1.5,
          color: AkariyuColors.textPrimary,
        ),
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.all(8),
          isCollapsed: true,
        ),
      ),
    );
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AkariyuColors.surfaceElevated,
        title: Text('Discard changes?',
            style: AkariyuTypography.titleLarge),
        content: Text(
          'You have unsaved edits. Leave anyway?',
          style: AkariyuTypography.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Discard',
                style: TextStyle(color: AkariyuColors.error)),
          ),
        ],
      ),
    );
    return ok ?? false;
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
