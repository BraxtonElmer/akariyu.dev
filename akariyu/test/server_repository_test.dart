import 'package:akariyu/core/ssh/ssh_models.dart';
import 'package:akariyu/core/storage/secure_storage.dart';
import 'package:akariyu/core/storage/server_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemorySecureStorageService storage;
  late ServerRepository repo;

  setUp(() {
    storage = InMemorySecureStorageService();
    repo = ServerRepository(storage);
  });

  ServerProfile makeProfile({
    String id = 'id-1',
    String name = 'dev',
    SshAuthMode mode = SshAuthMode.privateKey,
  }) =>
      ServerProfile(
        id: id,
        name: name,
        host: 'host',
        port: 22,
        username: 'u',
        authMode: mode,
      );

  test('save persists profile and index', () async {
    final p = makeProfile();
    await repo.save(p, privateKey: 'PEM');
    expect(await storage.readServerIndex(), ['id-1']);
    expect(await storage.readProfile('id-1'), isNotNull);
    expect(await storage.readPrivateKey('id-1'), 'PEM');
  });

  test('save with password authMode stores password and clears key', () async {
    await repo.save(makeProfile(mode: SshAuthMode.privateKey), privateKey: 'k1');
    expect(await storage.readPrivateKey('id-1'), 'k1');

    final pw = makeProfile(mode: SshAuthMode.password);
    await repo.save(pw, password: 'hunter2');
    expect(await storage.readPassword('id-1'), 'hunter2');
    expect(await storage.readPrivateKey('id-1'), isNull);
  });

  test('loadAll returns saved profiles', () async {
    await repo.save(makeProfile(id: 'a', name: 'A'), privateKey: 'k');
    await repo.save(makeProfile(id: 'b', name: 'B'), privateKey: 'k');
    final all = await repo.loadAll();
    expect(all.map((p) => p.id).toList(), containsAll(['a', 'b']));
  });

  test('loadAll skips corrupted entries without failing', () async {
    await repo.save(makeProfile(id: 'good'), privateKey: 'k');
    await storage.writeServerIndex(['good', 'corrupt']);
    await storage.writeProfile('corrupt', 'not-json{');
    final all = await repo.loadAll();
    expect(all.length, 1);
    expect(all.first.id, 'good');
  });

  test('delete removes profile, key, password, and index entry', () async {
    await repo.save(makeProfile(), privateKey: 'k');
    await repo.delete('id-1');
    expect(await storage.readProfile('id-1'), isNull);
    expect(await storage.readPrivateKey('id-1'), isNull);
    expect(await storage.readPassword('id-1'), isNull);
    expect(await storage.readServerIndex(), isEmpty);
  });

  test('generateId returns unique IDs', () {
    final a = repo.generateId();
    final b = repo.generateId();
    expect(a, isNot(b));
    expect(a.length, greaterThan(10));
  });

  test('save does not duplicate index entries on update', () async {
    final p = makeProfile();
    await repo.save(p, privateKey: 'k');
    await repo.save(p.copyWith(name: 'renamed'));
    final ids = await storage.readServerIndex();
    expect(ids, ['id-1']);
    final reloaded = await repo.load('id-1');
    expect(reloaded!.name, 'renamed');
  });
}
