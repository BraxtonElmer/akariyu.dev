import 'package:uuid/uuid.dart';

import '../ssh/ssh_models.dart';
import 'secure_storage.dart';

/// CRUD layer on top of [SecureStorageService] for [ServerProfile]s and their
/// associated secrets. All persistence flows through here so the UI never
/// pokes at storage keys directly.
class ServerRepository {
  ServerRepository(this._storage, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final SecureStorageService _storage;
  final Uuid _uuid;

  String generateId() => _uuid.v4();

  Future<List<ServerProfile>> loadAll() async {
    final ids = await _storage.readServerIndex();
    final out = <ServerProfile>[];
    for (final id in ids) {
      final raw = await _storage.readProfile(id);
      if (raw == null) continue;
      try {
        out.add(ServerProfile.decode(raw));
      } catch (_) {
        // Corrupted entry — skip but don't fail the whole load.
      }
    }
    return out;
  }

  Future<ServerProfile?> load(String id) async {
    final raw = await _storage.readProfile(id);
    if (raw == null) return null;
    return ServerProfile.decode(raw);
  }

  Future<void> save(
    ServerProfile profile, {
    String? privateKey,
    String? password,
  }) async {
    await _storage.writeProfile(profile.id, profile.encode());

    if (profile.authMode == SshAuthMode.privateKey) {
      if (privateKey != null) {
        await _storage.writePrivateKey(profile.id, privateKey);
      }
      await _storage.deletePassword(profile.id);
    } else {
      if (password != null) {
        await _storage.writePassword(profile.id, password);
      }
      await _storage.deletePrivateKey(profile.id);
    }

    final ids = await _storage.readServerIndex();
    if (!ids.contains(profile.id)) {
      ids.add(profile.id);
      await _storage.writeServerIndex(ids);
    }
  }

  Future<void> delete(String id) async {
    await _storage.deleteProfile(id);
    await _storage.deletePrivateKey(id);
    await _storage.deletePassword(id);
    final ids = await _storage.readServerIndex();
    ids.remove(id);
    await _storage.writeServerIndex(ids);
  }

  Future<String?> loadPrivateKey(String id) => _storage.readPrivateKey(id);
  Future<String?> loadPassword(String id) => _storage.readPassword(id);
}
