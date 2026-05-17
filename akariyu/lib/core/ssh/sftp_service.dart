import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import 'ssh_service.dart';

/// File / directory type, distilled from [SftpFileType].
enum FsEntryKind { directory, file, symlink, other }

/// Lightweight directory entry. We extract the fields we actually render from
/// [SftpName] / [SftpFileAttrs] so the UI layer never touches dartssh2 types.
class FsEntry {
  FsEntry({
    required this.name,
    required this.parent,
    required this.kind,
    required this.size,
    required this.modifiedAt,
    required this.permissionsMode,
    required this.linkTarget,
  });

  final String name;

  /// Absolute directory containing this entry (POSIX, ends without trailing /).
  final String parent;

  final FsEntryKind kind;
  final int size;
  final DateTime? modifiedAt;

  /// Unix mode bits (lower 9 bits = rwxrwxrwx). 0 when unknown.
  final int permissionsMode;

  /// For symlinks: the resolved target, if dartssh2 returned one. Null otherwise.
  final String? linkTarget;

  /// Absolute path on the server.
  String get path =>
      parent == '/' ? '/$name' : p.posix.join(parent, name);

  bool get isHidden => name.startsWith('.');
  bool get isDirectory => kind == FsEntryKind.directory;
  bool get isFile => kind == FsEntryKind.file;
  bool get isSymlink => kind == FsEntryKind.symlink;

  /// 9-char rwxrwxrwx string. Returns `?????????` if mode is unknown.
  String get permissionsString {
    if (permissionsMode == 0) return '?????????';
    final bits = [
      0x100, 0x080, 0x040, // u
      0x020, 0x010, 0x008, // g
      0x004, 0x002, 0x001, // o
    ];
    final chars = ['r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x'];
    final buf = StringBuffer();
    for (var i = 0; i < 9; i++) {
      buf.write((permissionsMode & bits[i]) != 0 ? chars[i] : '-');
    }
    return buf.toString();
  }
}

class SftpException implements Exception {
  const SftpException(this.message);
  final String message;
  @override
  String toString() => 'SftpException: $message';
}

class SftpTimeoutException extends SftpException {
  const SftpTimeoutException(super.message);
  @override
  String toString() => 'SftpTimeoutException: $message';
}

/// Format a byte count for human display: `1.4 MB`, `812 B`, etc.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Split an absolute POSIX path into breadcrumb segments. `/` → `[/]`,
/// `/home/u/p` → `[/, home, u, p]`.
List<String> pathSegments(String path) {
  if (path == '/' || path.isEmpty) return ['/'];
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  return ['/', ...parts];
}

/// Build the absolute path for breadcrumb index [i] within [segments] returned
/// from [pathSegments]. Index 0 is always the root.
String pathForSegment(List<String> segments, int i) {
  if (i == 0) return '/';
  return '/${segments.sublist(1, i + 1).join('/')}';
}

/// Wraps an [SftpClient] obtained from an active [SshConnection].
///
/// Instances are short-lived: created per file-browser session, closed
/// when the screen exits. The underlying SSH connection persists across
/// SFTP sessions via the connection manager.
class SftpService {
  SftpService._(this._client);

  final SftpClient _client;

  static Future<SftpService> open(SshConnection conn) async {
    if (conn.isClosed) {
      throw SftpException('SSH connection is closed');
    }
    final client = await conn.client.sftp();
    return SftpService._(client);
  }

  /// List the entries in [path]. Includes `.` and `..` filtered out.
  Future<List<FsEntry>> listDirectory(String path) async {
    try {
      final names = await _client.listdir(path);
      final out = <FsEntry>[];
      for (final n in names) {
        if (n.filename == '.' || n.filename == '..') continue;
        out.add(_toEntry(n, parent: path));
      }
      out.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return out;
    } on SftpStatusError catch (e) {
      throw SftpException('${e.message} ($path)');
    }
  }

  /// Resolve a relative path or `~` to its absolute form on the server.
  Future<String> resolveAbsolute(String path) async {
    try {
      return await _client.absolute(path);
    } on SftpStatusError catch (e) {
      throw SftpException('Could not resolve $path: ${e.message}');
    }
  }

  /// Read a regular file as UTF-8 text. Caps the read at [maxBytes] to avoid
  /// blowing memory on large binaries — anything larger throws.
  Future<String> readText(String path, {int maxBytes = 2 * 1024 * 1024}) async {
    try {
      final stat = await _client.stat(path);
      final size = stat.size ?? 0;
      if (size > maxBytes) {
        throw SftpException(
          'File is ${formatBytes(size)} — larger than the ${formatBytes(maxBytes)} editor limit.',
        );
      }
      final file = await _client.open(path, mode: SftpFileOpenMode.read);
      try {
        final bytes = await file.readBytes(length: size);
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        await file.close();
      }
    } on SftpStatusError catch (e) {
      throw SftpException(e.message);
    }
  }

  /// Read the first [maxBytes] of [path] as UTF-8 text. Unlike [readText],
  /// this never throws "file too big" — it just truncates. Useful for
  /// peeking at the first line of a large file.
  Future<String> readTextHead(String path, {int maxBytes = 8 * 1024}) async {
    try {
      final file = await _client.open(path, mode: SftpFileOpenMode.read);
      try {
        final bytes = await file.readBytes(length: maxBytes);
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        await file.close();
      }
    } on SftpStatusError catch (e) {
      throw SftpException(e.message);
    }
  }

  /// Overwrite [path] with [contents], creating it if needed.
  Future<void> writeText(String path, String contents) async {
    try {
      final file = await _client.open(
        path,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(Uint8List.fromList(utf8.encode(contents)));
      } finally {
        await file.close();
      }
    } on SftpStatusError catch (e) {
      throw SftpException(e.message);
    }
  }

  /// Binary equivalent of [writeText] — used for image/file uploads.
  /// Files larger than ~4 MB get streamed in chunks to keep the
  /// memory profile sane on mobile.
  Future<void> writeBytes(String path, Uint8List bytes) async {
    try {
      final file = await _client.open(
        path,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        const chunk = 64 * 1024;
        for (var offset = 0; offset < bytes.length; offset += chunk) {
          final end =
              (offset + chunk > bytes.length) ? bytes.length : offset + chunk;
          await file.writeBytes(
            Uint8List.sublistView(bytes, offset, end),
            offset: offset,
          );
        }
      } finally {
        await file.close();
      }
    } on SftpStatusError catch (e) {
      throw SftpException(e.message);
    }
  }

  /// True if [path] exists on the server (file, directory, symlink, …).
  /// Implemented via SFTP stat so we don't depend on shell semantics.
  Future<bool> exists(String path) async {
    try {
      await _client.stat(path);
      return true;
    } on SftpStatusError {
      return false;
    }
  }

  Future<void> mkdir(String path) async {
    try {
      await _client.mkdir(path);
    } on SftpStatusError catch (e) {
      throw SftpException(e.message);
    }
  }

  Future<void> remove(String path, {required bool isDirectory}) async {
    try {
      if (isDirectory) {
        await _client.rmdir(path);
      } else {
        await _client.remove(path);
      }
    } on SftpStatusError catch (e) {
      throw SftpException(e.message);
    }
  }

  Future<void> rename(String from, String to) async {
    try {
      await _client.rename(from, to);
    } on SftpStatusError catch (e) {
      throw SftpException(e.message);
    }
  }

  /// Create an empty file at [path]. Fails if it already exists.
  Future<void> touch(String path) async {
    try {
      final file = await _client.open(
        path,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.exclusive,
      );
      await file.close();
    } on SftpStatusError catch (e) {
      throw SftpException(e.message);
    }
  }

  void close() {
    // SftpClient does not need explicit close in dartssh2 2.17 — it's tied to
    // the SSH channel which the connection manager owns. Provided for future
    // symmetry if we add per-session channels.
  }

  FsEntry _toEntry(SftpName n, {required String parent}) {
    final attr = n.attr;
    final type = attr.type;
    final kind = switch (type) {
      SftpFileType.directory => FsEntryKind.directory,
      SftpFileType.regularFile => FsEntryKind.file,
      SftpFileType.symbolicLink => FsEntryKind.symlink,
      _ => FsEntryKind.other,
    };
    DateTime? mtime;
    final m = attr.modifyTime;
    if (m != null) {
      mtime = DateTime.fromMillisecondsSinceEpoch(m * 1000);
    }
    return FsEntry(
      name: n.filename,
      parent: parent,
      kind: kind,
      size: attr.size ?? 0,
      modifiedAt: mtime,
      permissionsMode: attr.mode?.value ?? 0,
      linkTarget: null,
    );
  }
}
