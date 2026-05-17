import 'package:akariyu/core/ssh/sftp_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBytes', () {
    test('formats sub-KB values verbatim', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('formats KB / MB / GB with one decimal', () {
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(5 * 1024 * 1024 + 500 * 1024), '5.5 MB');
      expect(formatBytes(1024 * 1024 * 1024 * 2), '2.0 GB');
    });

    test('drops decimal for 3-digit values', () {
      expect(formatBytes(200 * 1024), '200 KB');
    });
  });

  group('pathSegments / pathForSegment', () {
    test('root yields a single root segment', () {
      expect(pathSegments('/'), ['/']);
      expect(pathSegments(''), ['/']);
    });

    test('splits absolute paths', () {
      expect(pathSegments('/home/u/p'), ['/', 'home', 'u', 'p']);
    });

    test('rebuilds path from segment index', () {
      final segs = pathSegments('/home/u/p');
      expect(pathForSegment(segs, 0), '/');
      expect(pathForSegment(segs, 1), '/home');
      expect(pathForSegment(segs, 2), '/home/u');
      expect(pathForSegment(segs, 3), '/home/u/p');
    });
  });

  group('FsEntry', () {
    test('joins parent + name into absolute path', () {
      final e = FsEntry(
        name: 'foo.txt',
        parent: '/home/u',
        kind: FsEntryKind.file,
        size: 10,
        modifiedAt: null,
        permissionsMode: 0,
        linkTarget: null,
      );
      expect(e.path, '/home/u/foo.txt');
    });

    test('root-child path has no double slash', () {
      final e = FsEntry(
        name: 'etc',
        parent: '/',
        kind: FsEntryKind.directory,
        size: 0,
        modifiedAt: null,
        permissionsMode: 0,
        linkTarget: null,
      );
      expect(e.path, '/etc');
    });

    test('isHidden detects leading dot', () {
      FsEntry mk(String n) => FsEntry(
            name: n,
            parent: '/',
            kind: FsEntryKind.file,
            size: 0,
            modifiedAt: null,
            permissionsMode: 0,
            linkTarget: null,
          );
      expect(mk('.bashrc').isHidden, isTrue);
      expect(mk('README.md').isHidden, isFalse);
    });

    test('permissionsString renders rwx bits', () {
      final e = FsEntry(
        name: 'x',
        parent: '/',
        kind: FsEntryKind.file,
        size: 0,
        modifiedAt: null,
        permissionsMode: 0x1ED, // 0o755
        linkTarget: null,
      );
      expect(e.permissionsString, 'rwxr-xr-x');
    });

    test('permissionsString fallbacks for unknown mode', () {
      final e = FsEntry(
        name: 'x',
        parent: '/',
        kind: FsEntryKind.file,
        size: 0,
        modifiedAt: null,
        permissionsMode: 0,
        linkTarget: null,
      );
      expect(e.permissionsString, '?????????');
    });
  });
}
