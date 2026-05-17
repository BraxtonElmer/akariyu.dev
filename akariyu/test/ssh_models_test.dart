import 'package:akariyu/core/ssh/ssh_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerProfile', () {
    test('round-trips through JSON', () {
      final original = ServerProfile(
        id: 'abc-123',
        name: 'dev-server',
        host: '10.0.0.4',
        port: 2222,
        username: 'ubuntu',
        authMode: SshAuthMode.privateKey,
        defaultProjectPath: '/home/ubuntu/projects/pxls',
        lastConnectedAt: '2026-05-17T10:00:00.000Z',
      );
      final encoded = original.encode();
      final decoded = ServerProfile.decode(encoded);
      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.host, original.host);
      expect(decoded.port, original.port);
      expect(decoded.username, original.username);
      expect(decoded.authMode, original.authMode);
      expect(decoded.defaultProjectPath, original.defaultProjectPath);
      expect(decoded.lastConnectedAt, original.lastConnectedAt);
    });

    test('defaults to privateKey if authMode missing', () {
      final json = {
        'id': 'x',
        'name': 'n',
        'host': 'h',
        'port': 22,
        'username': 'u',
        'authMode': 'unknown_mode',
      };
      final decoded = ServerProfile.fromJson(json);
      expect(decoded.authMode, SshAuthMode.privateKey);
    });

    test('copyWith preserves id', () {
      final p = ServerProfile(
        id: 'fixed',
        name: 'a',
        host: 'h',
        port: 22,
        username: 'u',
        authMode: SshAuthMode.password,
      );
      final c = p.copyWith(name: 'b', host: 'h2');
      expect(c.id, 'fixed');
      expect(c.name, 'b');
      expect(c.host, 'h2');
      expect(c.authMode, SshAuthMode.password);
    });
  });

  group('SshCommandResult', () {
    test('ok iff exit code zero', () {
      expect(
        SshCommandResult(exitCode: 0, stdout: '', stderr: '').ok,
        isTrue,
      );
      expect(
        SshCommandResult(exitCode: 1, stdout: '', stderr: '').ok,
        isFalse,
      );
    });
  });

  group('ConnectionTestResult', () {
    test('success carries probe output', () {
      final r =
          ConnectionTestResult.success(whoami: 'ubuntu', uname: 'Linux x86');
      expect(r.ok, isTrue);
      expect(r.whoami, 'ubuntu');
      expect(r.uname, 'Linux x86');
      expect(r.error, isNull);
    });

    test('failure carries error string', () {
      final r = ConnectionTestResult.failure('boom');
      expect(r.ok, isFalse);
      expect(r.error, 'boom');
      expect(r.whoami, isNull);
    });
  });
}
