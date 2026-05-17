import 'package:path/path.dart' as p;

import '../ssh/sftp_service.dart';
import '../ssh/ssh_service.dart';
import 'claude_models.dart';
import 'claude_parser.dart';

/// Discovers and reads Claude Code's on-disk session store at
/// `~/.claude/projects/<encoded-path>/<session-uuid>.jsonl`.
class ClaudeService {
  ClaudeService({required this.sftp, required this.ssh});

  final SftpService sftp;
  final SshConnection ssh;

  /// Cached absolute path to `~/.claude/projects/` for this server, resolved
  /// the first time it's needed.
  String? _projectsRoot;

  Future<String> projectsRoot() async {
    final cached = _projectsRoot;
    if (cached != null) return cached;
    // SFTP REALPATH on `~` works on most OpenSSH servers; fall back to
    // running `echo $HOME` over the existing SSH connection if not.
    String home;
    try {
      home = await sftp.resolveAbsolute('.');
    } catch (_) {
      final res = await ssh.run('echo "\$HOME"',
          timeout: const Duration(seconds: 5));
      home = res.stdout.trim();
      if (home.isEmpty) home = '/root';
    }
    final root = p.posix.join(home, '.claude', 'projects');
    _projectsRoot = root;
    return root;
  }

  /// List every project directory under `~/.claude/projects/`. Sorted by
  /// most-recently-modified (i.e. most recently used in Claude Code).
  Future<List<ClaudeProject>> listProjects() async {
    final root = await projectsRoot();
    List<FsEntry> entries;
    try {
      entries = await sftp.listDirectory(root);
    } on SftpException catch (e) {
      // No projects dir yet — return empty.
      if (e.message.toLowerCase().contains('no such file')) {
        return const [];
      }
      rethrow;
    }
    final dirs = entries.where((e) => e.isDirectory).toList();

    final projects = <ClaudeProject>[];
    for (final d in dirs) {
      // Count sessions in this project.
      List<FsEntry> files;
      try {
        files = await sftp.listDirectory(d.path);
      } catch (_) {
        continue;
      }
      final sessions = files.where((f) => f.name.endsWith('.jsonl')).toList();
      DateTime? newest;
      for (final s in sessions) {
        if (s.modifiedAt == null) continue;
        if (newest == null || s.modifiedAt!.isAfter(newest)) {
          newest = s.modifiedAt;
        }
      }
      projects.add(ClaudeProject(
        encodedDirName: d.name,
        absoluteDir: d.path,
        sessionCount: sessions.length,
        lastModified: newest ?? d.modifiedAt,
      ));
    }

    projects.sort((a, b) {
      final at = a.lastModified;
      final bt = b.lastModified;
      if (at == null && bt == null) return a.encodedDirName.compareTo(b.encodedDirName);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return projects;
  }

  /// List sessions under [project], sorted newest first. Reads the full
  /// file to extract preview/first-message — for large session sets this
  /// can be slow, so callers should debounce or paginate.
  Future<List<ClaudeSession>> listSessions(ClaudeProject project,
      {int maxBytesPerFile = 256 * 1024}) async {
    final entries = await sftp.listDirectory(project.absoluteDir);
    final jsonl = entries
        .where((e) => e.isFile && e.name.endsWith('.jsonl'))
        .toList();

    final out = <ClaudeSession>[];
    for (final f in jsonl) {
      final id = f.name.endsWith('.jsonl')
          ? f.name.substring(0, f.name.length - 6)
          : f.name;
      ClaudeSessionMeta? meta;
      try {
        // Read up to maxBytesPerFile; for huge sessions we still get the
        // first user message + a reasonable preview. We re-read the full
        // file when the user opens the chat view.
        final body = await sftp.readText(f.path, maxBytes: maxBytesPerFile);
        meta = ClaudeSessionMeta.extract(body);
      } catch (_) {
        meta = null;
      }
      out.add(ClaudeSession(
        id: id,
        projectDir: project.encodedDirName,
        fileName: f.name,
        absolutePath: f.path,
        firstUserMessage: meta?.firstUserMessage,
        lastMessagePreview: meta?.lastMessagePreview,
        lastMessageAt: meta?.lastMessageAt ?? f.modifiedAt,
        messageCount: meta?.messageCount ?? 0,
      ));
    }

    out.sort((a, b) {
      final at = a.lastMessageAt;
      final bt = b.lastMessageAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return out;
  }

  /// Read + parse the full message history for [absolutePath].
  Future<List<ClaudeMessage>> readMessages(String absolutePath,
      {int maxBytes = 4 * 1024 * 1024}) async {
    final body = await sftp.readText(absolutePath, maxBytes: maxBytes);
    return ClaudeJsonlParser.parseAll(body);
  }
}
