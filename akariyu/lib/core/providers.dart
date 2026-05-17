import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/biometric_service.dart';
import 'ssh/ssh_models.dart';
import 'ssh/ssh_service.dart';
import 'storage/secure_storage.dart';
import 'storage/server_repository.dart';

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
