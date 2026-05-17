import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/providers.dart';
import '../../core/ssh/sftp_service.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../shared/widgets/akariyu_text_field.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// SFTP-backed file explorer for a single server. Starts at the user's home
/// directory unless [initialPath] is supplied.
class FileExplorerScreen extends ConsumerStatefulWidget {
  const FileExplorerScreen({
    super.key,
    required this.serverId,
    this.initialPath,
  });

  final String serverId;
  final String? initialPath;

  @override
  ConsumerState<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends ConsumerState<FileExplorerScreen> {
  String? _path;
  bool _showHidden = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    if (_path == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveHome());
    }
  }

  Future<void> _resolveHome() async {
    final home = await ref.read(homeDirectoryProvider(widget.serverId).future);
    if (mounted) setState(() => _path = home);
  }

  void _navigateTo(String path) {
    setState(() => _path = path);
  }

  Future<void> _refresh() async {
    if (_path == null) return;
    ref.invalidate(directoryListingProvider(
      DirectoryListingKey(serverId: widget.serverId, path: _path!),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            tooltip: _showHidden ? 'Hide dotfiles' : 'Show dotfiles',
            icon: Icon(_showHidden
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
          PopupMenuButton<String>(
            color: AkariyuColors.surfaceElevated,
            icon: const Icon(Icons.add),
            onSelected: (v) {
              if (_path == null) return;
              switch (v) {
                case 'newFile':
                  _promptCreate(isDirectory: false);
                  break;
                case 'newDir':
                  _promptCreate(isDirectory: true);
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'newFile', child: Text('New file')),
              PopupMenuItem(value: 'newDir', child: Text('New folder')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: _path == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _Breadcrumbs(path: _path!, onTap: _navigateTo),
                  _SearchBar(
                    value: _filter,
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                  Expanded(
                    child: _Listing(
                      serverId: widget.serverId,
                      path: _path!,
                      showHidden: _showHidden,
                      filter: _filter,
                      onTapDirectory: _navigateTo,
                      onRefresh: _refresh,
                      onEntryAction: _onEntryAction,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _onEntryAction(_EntryAction action, FsEntry entry) async {
    switch (action) {
      case _EntryAction.open:
        if (entry.isDirectory) {
          _navigateTo(entry.path);
        } else if (entry.isFile) {
          await context.push(
            '/server/${widget.serverId}/files/edit?path=${Uri.encodeQueryComponent(entry.path)}',
          );
        }
        break;
      case _EntryAction.copyPath:
        await Clipboard.setData(ClipboardData(text: entry.path));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Path copied')),
          );
        }
        break;
      case _EntryAction.rename:
        await _promptRename(entry);
        break;
      case _EntryAction.delete:
        await _confirmDelete(entry);
        break;
    }
  }

  Future<void> _promptCreate({required bool isDirectory}) async {
    final name = await _promptText(
      title: isDirectory ? 'New folder' : 'New file',
      hint: isDirectory ? 'folder-name' : 'filename.txt',
    );
    if (name == null || name.trim().isEmpty) return;
    final sftp = await ref.read(sftpServiceProvider(widget.serverId).future);
    final target = p.posix.join(_path!, name.trim());
    try {
      if (isDirectory) {
        await sftp.mkdir(target);
      } else {
        await sftp.touch(target);
      }
      await _refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _promptRename(FsEntry entry) async {
    final newName = await _promptText(
      title: 'Rename',
      hint: entry.name,
      initial: entry.name,
    );
    if (newName == null || newName.trim().isEmpty || newName == entry.name) {
      return;
    }
    final sftp = await ref.read(sftpServiceProvider(widget.serverId).future);
    final target = p.posix.join(entry.parent, newName.trim());
    try {
      await sftp.rename(entry.path, target);
      await _refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _confirmDelete(FsEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AkariyuColors.surfaceElevated,
        title: Text('Delete ${entry.name}?',
            style: AkariyuTypography.titleLarge),
        content: Text(
          entry.isDirectory
              ? 'Deletes the empty folder. Non-empty folders must be removed via terminal.'
              : 'Deletes this file from the server.',
          style: AkariyuTypography.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete',
                style: TextStyle(color: AkariyuColors.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final sftp = await ref.read(sftpServiceProvider(widget.serverId).future);
    try {
      await sftp.remove(entry.path, isDirectory: entry.isDirectory);
      await _refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
    String? initial,
  }) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AkariyuColors.surfaceElevated,
        title: Text(title, style: AkariyuTypography.titleLarge),
        content: AkariyuTextField(controller: ctrl, hint: hint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(e.toString()),
        backgroundColor: AkariyuColors.surfaceCard,
      ),
    );
  }
}

enum _EntryAction { open, copyPath, rename, delete }

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.path, required this.onTap});
  final String path;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final segments = pathSegments(path);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.chevron_right,
                    size: 14, color: AkariyuColors.textTertiary),
              ),
            InkWell(
              onTap: () => onTap(pathForSegment(segments, i)),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  segments[i] == '/' ? '~/' : segments[i],
                  style: AkariyuTypography.monoSmall.copyWith(
                    color: i == segments.length - 1
                        ? AkariyuColors.textPrimary
                        : AkariyuColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: AkariyuTextField(
        hint: 'Filter in this folder',
        prefixIcon: Icons.search,
        onChanged: onChanged,
      ),
    );
  }
}

class _Listing extends ConsumerWidget {
  const _Listing({
    required this.serverId,
    required this.path,
    required this.showHidden,
    required this.filter,
    required this.onTapDirectory,
    required this.onRefresh,
    required this.onEntryAction,
  });

  final String serverId;
  final String path;
  final bool showHidden;
  final String filter;
  final ValueChanged<String> onTapDirectory;
  final Future<void> Function() onRefresh;
  final Future<void> Function(_EntryAction, FsEntry) onEntryAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listing = ref.watch(directoryListingProvider(
      DirectoryListingKey(serverId: serverId, path: path),
    ));

    return RefreshIndicator(
      color: AkariyuColors.accent,
      onRefresh: onRefresh,
      child: listing.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(message: e.toString(), onRetry: onRefresh),
        data: (entries) {
          final visible = entries.where((e) {
            if (!showHidden && e.isHidden) return false;
            if (filter.isEmpty) return true;
            return e.name.toLowerCase().contains(filter.toLowerCase());
          }).toList();
          if (visible.isEmpty) {
            return ListView(
              children: const [
                SizedBox(height: 80),
                Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Empty'),
                  ),
                ),
              ],
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 2),
            itemBuilder: (_, i) => _EntryTile(
              entry: visible[i],
              onAction: onEntryAction,
            ),
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onAction});
  final FsEntry entry;
  final Future<void> Function(_EntryAction, FsEntry) onAction;

  IconData _iconFor(FsEntry e) {
    if (e.isDirectory) return Icons.folder_outlined;
    if (e.isSymlink) return Icons.link;
    final ext = p.extension(e.name).toLowerCase();
    switch (ext) {
      case '.dart':
      case '.js':
      case '.ts':
      case '.tsx':
      case '.jsx':
      case '.py':
      case '.go':
      case '.rs':
      case '.java':
      case '.kt':
      case '.swift':
      case '.c':
      case '.h':
      case '.cpp':
      case '.rb':
      case '.php':
        return Icons.code;
      case '.json':
      case '.yaml':
      case '.yml':
      case '.toml':
      case '.ini':
      case '.cfg':
        return Icons.data_object;
      case '.md':
      case '.markdown':
      case '.rst':
      case '.txt':
        return Icons.text_snippet_outlined;
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.webp':
      case '.svg':
        return Icons.image_outlined;
      case '.zip':
      case '.tar':
      case '.gz':
      case '.bz2':
      case '.xz':
      case '.7z':
        return Icons.archive_outlined;
      case '.sh':
      case '.bash':
      case '.zsh':
      case '.fish':
        return Icons.terminal_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final modified = entry.modifiedAt;
    return InkWell(
      onTap: () => onAction(_EntryAction.open, entry),
      onLongPress: () => _showActions(context),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              _iconFor(entry),
              size: 20,
              color: entry.isDirectory
                  ? AkariyuColors.accent
                  : AkariyuColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: AkariyuTypography.bodyLarge.copyWith(
                      color: AkariyuColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (entry.isFile) formatBytes(entry.size),
                      if (modified != null) _formatTimestamp(modified),
                      entry.permissionsString,
                    ].join(' · '),
                    style: AkariyuTypography.monoSmall.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.more_horiz, color: AkariyuColors.textTertiary),
              onPressed: () => _showActions(context),
            ),
          ],
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy path'),
              onTap: () {
                Navigator.pop(context);
                onAction(_EntryAction.copyPath, entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(context);
                onAction(_EntryAction.rename, entry);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: AkariyuColors.error),
              title: Text('Delete',
                  style: TextStyle(color: AkariyuColors.error)),
              onTap: () {
                Navigator.pop(context);
                onAction(_EntryAction.delete, entry);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inDays > 365) return '${(diff.inDays / 365).floor()}y ago';
    if (diff.inDays > 30) return '${(diff.inDays / 30).floor()}mo ago';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                Icon(Icons.error_outline,
                    size: 40, color: AkariyuColors.error),
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
        ),
      ],
    );
  }
}
