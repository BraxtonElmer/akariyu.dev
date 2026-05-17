import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/biometric_service.dart';
import 'claude/claude_models.dart';
import 'claude/claude_service.dart';
import 'ssh/sftp_service.dart';
import 'ssh/ssh_models.dart';
import 'ssh/ssh_service.dart';
import 'storage/secure_storage.dart';
import 'storage/server_repository.dart';
import 'tmux/terminal_session.dart';

/// Root provider for secure storage. Overridden in tests with the in-memory impl.
final secureStorageProvider = Provider<SecureStorageService>((ref) {
  return SecureStorageServiceImpl();
});

final serverRepositoryProvider = Provider<ServerRepository>((ref) {
  return ServerRepository(ref.watch(secureStorageProvider));
});

final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});

/// All known server profiles. Refreshed via [refresh].
final serverListProvider =
    AsyncNotifierProvider<ServerListNotifier, List<ServerProfile>>(
        ServerListNotifier.new);

class ServerListNotifier extends AsyncNotifier<List<ServerProfile>> {
  @override
  Future<List<ServerProfile>> build() async {
    return ref.read(serverRepositoryProvider).loadAll();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(serverRepositoryProvider).loadAll(),
    );
  }

  Future<void> add(
    ServerProfile profile, {
    String? privateKey,
    String? password,
  }) async {
    final repo = ref.read(serverRepositoryProvider);
    await repo.save(profile, privateKey: privateKey, password: password);
    await refresh();
  }

  Future<void> remove(String id) async {
    await ref.read(serverRepositoryProvider).delete(id);
    final conns = ref.read(connectionManagerProvider);
    await conns.disconnect(id);
    await refresh();
  }

  Future<void> touch(String id) async {
    final repo = ref.read(serverRepositoryProvider);
    final existing = await repo.load(id);
    if (existing == null) return;
    final updated =
        existing.copyWith(lastConnectedAt: DateTime.now().toIso8601String());
    await repo.save(updated);
    await refresh();
  }
}

/// Tracks live SSH connections keyed by [ServerProfile.id]. State is
/// surfaced as a map id → [SshConnectionState] for UI subscriptions.
final connectionManagerProvider =
    Provider<ConnectionManager>((ref) => ConnectionManager(ref));

class ConnectionManager {
  ConnectionManager(this._ref);

  final Ref _ref;
  final Map<String, SshConnection> _connections = {};
  final Map<String, SshConnectionState> _states = {};
  final StreamController<Map<String, SshConnectionState>> _stateController =
      StreamController.broadcast();

  Stream<Map<String, SshConnectionState>> get stateStream =>
      _stateController.stream;

  Map<String, SshConnectionState> get states => Map.unmodifiable(_states);

  SshConnectionState stateFor(String id) =>
      _states[id] ?? SshConnectionState.disconnected;

  SshConnection? connectionFor(String id) => _connections[id];

  void _setState(String id, SshConnectionState s) {
    _states[id] = s;
    _stateController.add(states);
  }

  Future<SshConnection> connect(String id) async {
    final existing = _connections[id];
    if (existing != null && !existing.isClosed) return existing;

    _setState(id, SshConnectionState.connecting);
    final repo = _ref.read(serverRepositoryProvider);
    final profile = await repo.load(id);
    if (profile == null) {
      _setState(id, SshConnectionState.error);
      throw SshConnectionException('Unknown server: $id');
    }
    final pk = await repo.loadPrivateKey(id);
    final pw = await repo.loadPassword(id);

    try {
      final conn = await SshConnection.connect(
        profile: profile,
        privateKey: pk,
        password: pw,
      );
      _connections[id] = conn;
      _setState(id, SshConnectionState.connected);
      await _ref.read(serverListProvider.notifier).touch(id);
      return conn;
    } catch (e) {
      _setState(id, SshConnectionState.error);
      rethrow;
    }
  }

  Future<void> disconnect(String id) async {
    final conn = _connections.remove(id);
    if (conn != null) await conn.close();
    _setState(id, SshConnectionState.disconnected);
  }

  Future<void> disconnectAll() async {
    for (final id in _connections.keys.toList()) {
      await disconnect(id);
    }
  }

  Future<SshConnection> reconnect(String id) async {
    await disconnect(id);
    _setState(id, SshConnectionState.reconnecting);
    return connect(id);
  }
}

/// Stream of state for one server — used by [StatusDot] etc.
final connectionStateProvider =
    StreamProvider.family<SshConnectionState, String>((ref, id) {
  final mgr = ref.watch(connectionManagerProvider);
  return mgr.stateStream
      .map((m) => m[id] ?? SshConnectionState.disconnected)
      .distinct();
});

/// Opens an [SftpService] over the currently-active SSH connection for
/// server [id]. Auto-connects if needed. Kept alive while at least one
/// screen has read it once — the connection manager owns full lifecycle.
final sftpServiceProvider =
    FutureProvider.family<SftpService, String>((ref, id) async {
  final mgr = ref.read(connectionManagerProvider);
  final conn = mgr.connectionFor(id) ?? await mgr.connect(id);
  final service = await SftpService.open(conn)
      .timeout(const Duration(seconds: 15),
          onTimeout: () => throw const SftpTimeoutException(
              'SFTP subsystem did not respond within 15s'));
  ref.onDispose(service.close);
  return service;
});

/// Directory listing for ([serverId], absolutePath). Cached by Riverpod —
/// the file explorer calls `ref.invalidate` on pull-to-refresh.
final directoryListingProvider = FutureProvider.autoDispose
    .family<List<FsEntry>, DirectoryListingKey>((ref, key) async {
  final sftp = await ref.watch(sftpServiceProvider(key.serverId).future);
  return sftp.listDirectory(key.path);
});

class DirectoryListingKey {
  const DirectoryListingKey({required this.serverId, required this.path});
  final String serverId;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is DirectoryListingKey &&
      other.serverId == serverId &&
      other.path == path;
  @override
  int get hashCode => Object.hash(serverId, path);
}

/// Resolves the user's home directory on the server (used as default root
/// for the file explorer). Cached for the connection lifetime.
final homeDirectoryProvider =
    FutureProvider.autoDispose.family<String, String>((ref, serverId) async {
  final sftp = await ref.watch(sftpServiceProvider(serverId).future);
  return sftp.resolveAbsolute('.');
});

/// Long-lived [ClaudeService] for a given server. Backed by the same
/// SFTP + SSH connections used elsewhere.
final claudeServiceProvider =
    FutureProvider.family<ClaudeService, String>((ref, serverId) async {
  final mgr = ref.read(connectionManagerProvider);
  final conn = mgr.connectionFor(serverId) ?? await mgr.connect(serverId);
  final sftp = await ref.watch(sftpServiceProvider(serverId).future);
  return ClaudeService(sftp: sftp, ssh: conn);
});

/// All projects under `~/.claude/projects/` on [serverId].
final claudeProjectsProvider = FutureProvider.autoDispose
    .family<List<ClaudeProject>, String>((ref, serverId) async {
  final service = await ref.watch(claudeServiceProvider(serverId).future);
  return service.listProjects();
});

/// Sessions inside one project, keyed by (serverId, encodedDirName).
final claudeSessionsProvider = FutureProvider.autoDispose
    .family<List<ClaudeSession>, ClaudeSessionsKey>((ref, key) async {
  final service = await ref.watch(claudeServiceProvider(key.serverId).future);
  final projects = await service.listProjects();
  final project = projects.firstWhere(
    (p) => p.encodedDirName == key.encodedDirName,
    orElse: () => ClaudeProject(
      encodedDirName: key.encodedDirName,
      absoluteDir: '',
      sessionCount: 0,
      lastModified: null,
    ),
  );
  if (project.absoluteDir.isEmpty) return const [];
  return service.listSessions(project);
});

class ClaudeSessionsKey {
  const ClaudeSessionsKey({
    required this.serverId,
    required this.encodedDirName,
  });
  final String serverId;
  final String encodedDirName;

  @override
  bool operator ==(Object other) =>
      other is ClaudeSessionsKey &&
      other.serverId == serverId &&
      other.encodedDirName == encodedDirName;
  @override
  int get hashCode => Object.hash(serverId, encodedDirName);
}

/// Parsed message history for one session JSONL file.
final claudeChatHistoryProvider = FutureProvider.autoDispose
    .family<List<ClaudeMessage>, ClaudeChatKey>((ref, key) async {
  final service = await ref.watch(claudeServiceProvider(key.serverId).future);
  return service.readMessages(key.absolutePath);
});

class ClaudeChatKey {
  const ClaudeChatKey({
    required this.serverId,
    required this.absolutePath,
  });
  final String serverId;
  final String absolutePath;

  @override
  bool operator ==(Object other) =>
      other is ClaudeChatKey &&
      other.serverId == serverId &&
      other.absolutePath == absolutePath;
  @override
  int get hashCode => Object.hash(serverId, absolutePath);
}

/// Multi-tab terminal state, keyed by server id.
final terminalTabsProvider = NotifierProvider.family<TerminalTabsNotifier,
    List<TerminalSession>, String>(TerminalTabsNotifier.new);

class TerminalTabsNotifier
    extends FamilyNotifier<List<TerminalSession>, String> {
  @override
  List<TerminalSession> build(String serverId) => const [];

  Future<TerminalSession> open({String? cwd, String? title}) async {
    final mgr = ref.read(connectionManagerProvider);
    final conn = mgr.connectionFor(arg) ?? await mgr.connect(arg);
    final session = await TerminalSession.start(
      conn: conn,
      title: title ?? 'shell ${state.length + 1}',
      cwd: cwd,
    );
    state = [...state, session];
    return session;
  }

  Future<void> closeTab(String id, {bool killTmux = false}) async {
    final session = state.firstWhere(
      (s) => s.id == id,
      orElse: () => throw StateError('No terminal $id'),
    );
    final mgr = ref.read(connectionManagerProvider);
    final conn = mgr.connectionFor(arg);
    if (killTmux && conn != null) {
      await session.kill(conn);
    } else {
      await session.detach();
    }
    state = state.where((s) => s.id != id).toList();
  }

  Future<void> closeAll() async {
    for (final s in state) {
      await s.detach();
    }
    state = const [];
  }
}
