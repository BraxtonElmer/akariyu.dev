import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_models.dart';

/// Holds an active SSH connection for one [ServerProfile].
///
/// Owns the [SSHClient] lifecycle and exposes high-level helpers used by the
/// services layered above (SFTP, tmux, monitor, git). Reconnect is exposed
/// explicitly — callers (Riverpod providers) drive retry policy.
class SshConnection {
  SshConnection._({
    required this.profile,
    required SSHClient client,
    required SSHSocket socket,
  })  : _client = client,
        _socket = socket;

  final ServerProfile profile;
  final SSHClient _client;
  final SSHSocket _socket;
  bool _closed = false;

  /// Connect to [profile] using the supplied credential (PEM-encoded private
  /// key with optional passphrase, or password).
  ///
  /// Throws [SshAuthenticationException] on bad keys/credentials and
  /// [SshConnectionException] on network / handshake failures.
  static Future<SshConnection> connect({
    required ServerProfile profile,
    String? privateKey,
    String? passphrase,
    String? password,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        profile.host,
        profile.port,
        timeout: timeout,
      );
    } on SocketException catch (e) {
      throw SshConnectionException('Could not reach ${profile.host}: ${e.message}');
    } on TimeoutException {
      throw SshConnectionException('Timed out connecting to ${profile.host}');
    }

    List<SSHKeyPair>? identities;
    if (profile.authMode == SshAuthMode.privateKey) {
      if (privateKey == null || privateKey.isEmpty) {
        await socket.close();
        throw SshAuthenticationException('Missing private key for ${profile.name}');
      }
      try {
        identities = SSHKeyPair.fromPem(privateKey, passphrase);
      } on SSHKeyDecryptError {
        await socket.close();
        throw SshAuthenticationException(
          passphrase == null
              ? 'Private key is encrypted — passphrase required'
              : 'Wrong passphrase for private key',
        );
      } catch (e) {
        await socket.close();
        throw SshAuthenticationException('Invalid private key: $e');
      }
    }

    final SSHClient client;
    try {
      client = SSHClient(
        socket,
        username: profile.username,
        identities: identities,
        onPasswordRequest: () => password,
      );
      await client.authenticated;
    } on SSHAuthAbortError catch (e) {
      await socket.close();
      throw SshAuthenticationException('Authentication aborted: ${e.message}');
    } on SSHAuthFailError catch (e) {
      await socket.close();
      throw SshAuthenticationException('Authentication rejected: ${e.message}');
    } catch (e) {
      await socket.close();
      throw SshConnectionException('Handshake failed: $e');
    }

    return SshConnection._(profile: profile, client: client, socket: socket);
  }

  bool get isClosed => _closed || _client.isClosed;

  /// Run a one-shot command and capture stdout + stderr + exit code.
  ///
  /// Note: `dartssh2` returns the exit code via [SSHSession.exitCode], which
  /// may be `null` for a clean disconnect; we coerce to `-1` in that case.
  Future<SshCommandResult> run(String command, {Duration? timeout}) async {
    if (isClosed) throw SshConnectionException('Connection is closed');
    final session = await _client.execute(command);
    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];

    final stdoutSub = session.stdout.listen(stdoutBytes.addAll);
    final stderrSub = session.stderr.listen(stderrBytes.addAll);

    Future<void> done = session.done;
    if (timeout != null) {
      done = done.timeout(timeout, onTimeout: () async {
        session.close();
      });
    }
    await done;
    await stdoutSub.cancel();
    await stderrSub.cancel();

    return SshCommandResult(
      exitCode: session.exitCode ?? -1,
      stdout: utf8.decode(stdoutBytes, allowMalformed: true),
      stderr: utf8.decode(stderrBytes, allowMalformed: true),
    );
  }

  /// "Test connection" probe used by onboarding. Runs `whoami` and `uname -a`.
  Future<ConnectionTestResult> probe() async {
    try {
      final who = await run('whoami', timeout: const Duration(seconds: 10));
      if (!who.ok) {
        return ConnectionTestResult.failure(
          'whoami failed (exit ${who.exitCode}): ${who.stderr.trim()}',
        );
      }
      final uname = await run('uname -a', timeout: const Duration(seconds: 10));
      return ConnectionTestResult.success(
        whoami: who.stdout.trim(),
        uname: uname.stdout.trim(),
      );
    } catch (e) {
      return ConnectionTestResult.failure(e.toString());
    }
  }

  /// Tear down the session. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close();
    await _client.done;
    await _socket.close();
  }

  /// Expose the underlying client for SFTP / port-forward consumers.
  SSHClient get client => _client;
}
