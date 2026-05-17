import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper around [FlutterSecureStorage] with akariyu-specific key
/// namespaces. Backed by iOS Keychain / Android Keystore.
///
/// We segregate three buckets:
///   - `profile:<id>`  → JSON server profile (no secret material)
///   - `key:<id>`      → SSH private key PEM
///   - `pass:<id>`     → SSH password (when authMode == password)
///   - `app:*`         → app-wide settings (e.g. server index, biometric)
abstract class SecureStorageService {
  Future<void> writeProfile(String id, String profileJson);
  Future<String?> readProfile(String id);
  Future<void> deleteProfile(String id);

  Future<void> writePrivateKey(String id, String pem);
  Future<String?> readPrivateKey(String id);
  Future<void> deletePrivateKey(String id);

  Future<void> writePassword(String id, String password);
  Future<String?> readPassword(String id);
  Future<void> deletePassword(String id);

  Future<void> writeServerIndex(List<String> ids);
  Future<List<String>> readServerIndex();

  Future<void> writeAppValue(String key, String value);
  Future<String?> readAppValue(String key);
  Future<void> deleteAppValue(String key);

  Future<void> wipeAll();
}

class SecureStorageServiceImpl implements SecureStorageService {
  SecureStorageServiceImpl({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: true,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _storage;

  static const _indexKey = 'app:serverIndex';

  @override
  Future<void> writeProfile(String id, String profileJson) =>
      _storage.write(key: 'profile:$id', value: profileJson);

  @override
  Future<String?> readProfile(String id) =>
      _storage.read(key: 'profile:$id');

  @override
  Future<void> deleteProfile(String id) =>
      _storage.delete(key: 'profile:$id');

  @override
  Future<void> writePrivateKey(String id, String pem) =>
      _storage.write(key: 'key:$id', value: pem);

  @override
  Future<String?> readPrivateKey(String id) =>
      _storage.read(key: 'key:$id');

  @override
  Future<void> deletePrivateKey(String id) =>
      _storage.delete(key: 'key:$id');

  @override
  Future<void> writePassword(String id, String password) =>
      _storage.write(key: 'pass:$id', value: password);

  @override
  Future<String?> readPassword(String id) =>
      _storage.read(key: 'pass:$id');

  @override
  Future<void> deletePassword(String id) =>
      _storage.delete(key: 'pass:$id');

  @override
  Future<void> writeServerIndex(List<String> ids) =>
      _storage.write(key: _indexKey, value: ids.join(','));

  @override
  Future<List<String>> readServerIndex() async {
    final raw = await _storage.read(key: _indexKey);
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<void> writeAppValue(String key, String value) =>
      _storage.write(key: 'app:$key', value: value);

  @override
  Future<String?> readAppValue(String key) => _storage.read(key: 'app:$key');

  @override
  Future<void> deleteAppValue(String key) => _storage.delete(key: 'app:$key');

  @override
  Future<void> wipeAll() => _storage.deleteAll();
}

/// In-memory storage used by unit tests. Keeps the real `flutter_secure_storage`
/// out of the test process so we don't need platform channels.
class InMemorySecureStorageService implements SecureStorageService {
  final Map<String, String> _data = {};

  @override
  Future<void> writeProfile(String id, String profileJson) async {
    _data['profile:$id'] = profileJson;
  }

  @override
  Future<String?> readProfile(String id) async => _data['profile:$id'];

  @override
  Future<void> deleteProfile(String id) async {
    _data.remove('profile:$id');
  }

  @override
  Future<void> writePrivateKey(String id, String pem) async {
    _data['key:$id'] = pem;
  }

  @override
  Future<String?> readPrivateKey(String id) async => _data['key:$id'];

  @override
  Future<void> deletePrivateKey(String id) async {
    _data.remove('key:$id');
  }

  @override
  Future<void> writePassword(String id, String password) async {
    _data['pass:$id'] = password;
  }

  @override
  Future<String?> readPassword(String id) async => _data['pass:$id'];

  @override
  Future<void> deletePassword(String id) async {
    _data.remove('pass:$id');
  }

  @override
  Future<void> writeServerIndex(List<String> ids) async {
    _data['app:serverIndex'] = ids.join(',');
  }

  @override
  Future<List<String>> readServerIndex() async {
    final raw = _data['app:serverIndex'];
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<void> writeAppValue(String key, String value) async {
    _data['app:$key'] = value;
  }

  @override
  Future<String?> readAppValue(String key) async => _data['app:$key'];

  @override
  Future<void> deleteAppValue(String key) async {
    _data.remove('app:$key');
  }

  @override
  Future<void> wipeAll() async => _data.clear();
}
