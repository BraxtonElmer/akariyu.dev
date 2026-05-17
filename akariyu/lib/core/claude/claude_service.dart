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

    // Fan out per-project work — each iteration is two sequential SFTP
    // round-trips (listdir + peek for cwd), so doing them serially makes
    // the projects screen feel sluggish on servers with many projects.
    final results = await Future.wait(dirs.map(_loadProjectSummary));
    final projects = results.whereType<ClaudeProject>().toList();

    projects.sort((a, b) {
      final at = a.lastModified;
      final bt = b.lastModified;
      if (at == null && bt == null) {
        return a.encodedDirName.compareTo(b.encodedDirName);
      }
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return projects;
  }

  /// Load one project's summary (session count + newest mtime + cwd) in
  /// one task so the caller can [Future.wait] across all projects.
  Future<ClaudeProject?> _loadProjectSummary(FsEntry dir) async {
    List<FsEntry> files;
    try {
      files = await sftp.listDirectory(dir.path);
    } catch (_) {
      return null;
    }
    final sessions = files.where((f) => f.name.endsWith('.jsonl')).toList();
    DateTime? newest;
    FsEntry? newestEntry;
    for (final s in sessions) {
      if (s.modifiedAt == null) continue;
      if (newest == null || s.modifiedAt!.isAfter(newest)) {
        newest = s.modifiedAt;
        newestEntry = s;
      }
    }
    final cwd = await _peekCwd(
      newestEntry ?? (sessions.isEmpty ? null : sessions.first),
    );
    return ClaudeProject(
      encodedDirName: dir.name,
      absoluteDir: dir.path,
      sessionCount: sessions.length,
      lastModified: newest ?? dir.modifiedAt,
      cwd: cwd,
    );
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

    // Read all sessions in parallel. Each is at most one SFTP round-trip
    // (stat + open + read + close), so fanning out shaves seconds off the
    // sessions screen on projects with 10+ sessions.
    final out = await Future.wait(jsonl.map((f) async {
      final id = f.name.endsWith('.jsonl')
          ? f.name.substring(0, f.name.length - 6)
          : f.name;
      ClaudeSessionMeta? meta;
      try {
        final body =
            await sftp.readTextHead(f.path, maxBytes: maxBytesPerFile);
        meta = ClaudeSessionMeta.extract(body);
      } catch (_) {
        meta = null;
      }
      return ClaudeSession(
        id: id,
        projectDir: project.encodedDirName,
        fileName: f.name,
        absolutePath: f.path,
        firstUserMessage: meta?.firstUserMessage,
        lastMessagePreview: meta?.lastMessagePreview,
        lastMessageAt: meta?.lastMessageAt ?? f.modifiedAt,
        messageCount: meta?.messageCount ?? 0,
      );
    }));

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

  /// Pull `cwd` from the first non-empty JSONL line of [entry] that has
  /// one. Used by [listProjects] to get an accurate project path without
  /// reading every session in full.
  ///
  /// Scans up to the first ~32 lines because some JSONL files start with
  /// a `summary` row or other event that doesn't carry `cwd`.
  Future<String?> _peekCwd(FsEntry? entry) async {
    if (entry == null) return null;
    try {
      final body = await sftp.readTextHead(entry.path, maxBytes: 32 * 1024);
      var scanned = 0;
      for (final line in body.split('\n')) {
        if (scanned++ > 32) break;
        if (line.trim().isEmpty) continue;
        final msg = ClaudeJsonlParser.parseLine(line);
        final cwd = msg?.cwd;
        if (cwd != null && cwd.isNotEmpty) return cwd;
      }
    } catch (_) {
      // Best-effort — fall through to dir-name decoding.
    }
    return null;
  }
}
