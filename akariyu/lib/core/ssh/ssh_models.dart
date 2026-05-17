import 'dart:convert';

/// Authentication method for a server.
enum SshAuthMode { privateKey, password }

/// A server profile stored on the device. Holds connection metadata
/// (host/port/user/auth) but never the secret material — the private key
/// or password lives in [SecureStorageService] keyed by [id].
class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authMode,
    this.defaultProjectPath,
    this.lastConnectedAt,
  });

  /// Stable UUID. Used as the secret-storage key suffix.
  final String id;

  /// Human-readable name (e.g. "dev-server", "braxtonserver").
  final String name;

  final String host;
  final int port;
  final String username;
  final SshAuthMode authMode;

  /// Optional default project (absolute path on the server).
  final String? defaultProjectPath;

  /// ISO-8601 timestamp of the most recent successful connection, if any.
  final String? lastConnectedAt;

  ServerProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    SshAuthMode? authMode,
    String? defaultProjectPath,
    String? lastConnectedAt,
  }) {
    return ServerProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMode: authMode ?? this.authMode,
      defaultProjectPath: defaultProjectPath ?? this.defaultProjectPath,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'authMode': authMode.name,
        'defaultProjectPath': defaultProjectPath,
        'lastConnectedAt': lastConnectedAt,
      };

  static ServerProfile fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: (json['port'] as num).toInt(),
      username: json['username'] as String,
      authMode: SshAuthMode.values.firstWhere(
        (e) => e.name == json['authMode'],
        orElse: () => SshAuthMode.privateKey,
      ),
      defaultProjectPath: json['defaultProjectPath'] as String?,
      lastConnectedAt: json['lastConnectedAt'] as String?,
    );
  }

  String encode() => jsonEncode(toJson());
  static ServerProfile decode(String s) =>
      fromJson(jsonDecode(s) as Map<String, dynamic>);
}

/// Result of a connection attempt — used by the onboarding "Test connection" flow.
class ConnectionTestResult {
  ConnectionTestResult.success({required this.whoami, required this.uname})
      : ok = true,
        error = null;

  ConnectionTestResult.failure(this.error)
      : ok = false,
        whoami = null,
        uname = null;

  final bool ok;
  final String? whoami;
  final String? uname;
  final String? error;
}

/// Live state of an SSH connection. Surfaced to the UI via [StatusDot].
enum SshConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

class SshCommandResult {
  SshCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  @override
  String toString() =>
      'SshCommandResult(exit=$exitCode, stdout=${stdout.length}B, stderr=${stderr.length}B)';
}

class SshAuthenticationException implements Exception {
  SshAuthenticationException(this.message);
  final String message;
  @override
  String toString() => 'SshAuthenticationException: $message';
}

class SshConnectionException implements Exception {
  SshConnectionException(this.message);
  final String message;
  @override
  String toString() => 'SshConnectionException: $message';
}
