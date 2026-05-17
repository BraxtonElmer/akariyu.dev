import 'package:akariyu/core/providers.dart';
import 'package:akariyu/core/ssh/ssh_models.dart';
import 'package:akariyu/core/storage/secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemorySecureStorageService storage;
  late ProviderContainer container;

  setUp(() {
    storage = InMemorySecureStorageService();
    container = ProviderContainer(overrides: [
      secureStorageProvider.overrideWithValue(storage),
    ]);
  });

  tearDown(() {
    container.dispose();
  });

  ServerProfile profile(String id) => ServerProfile(
        id: id,
        name: 'srv-$id',
        host: 'h-$id',
        port: 22,
        username: 'u',
        authMode: SshAuthMode.privateKey,
      );

  test('serverListProvider starts empty when storage is empty', () async {
    final list = await container.read(serverListProvider.future);
    expect(list, isEmpty);
  });

  test('add inserts and refreshes the list', () async {
    await container.read(serverListProvider.future);
    await container.read(serverListProvider.notifier).add(
          profile('a'),
          privateKey: 'PEM',
        );
    final list = await container.read(serverListProvider.future);
    expect(list.length, 1);
    expect(list.first.id, 'a');
  });

  test('remove deletes from storage and refreshes', () async {
    await container.read(serverListProvider.future);
    final notifier = container.read(serverListProvider.notifier);
    await notifier.add(profile('a'), privateKey: 'k');
    await notifier.add(profile('b'), privateKey: 'k');
    await notifier.remove('a');
    final list = await container.read(serverListProvider.future);
    expect(list.map((p) => p.id).toList(), ['b']);
  });

  test('touch updates lastConnectedAt', () async {
    await container.read(serverListProvider.future);
    final notifier = container.read(serverListProvider.notifier);
    await notifier.add(profile('a'), privateKey: 'k');
    await notifier.touch('a');
    final list = await container.read(serverListProvider.future);
    expect(list.first.lastConnectedAt, isNotNull);
  });

  test('connection manager reports disconnected for unknown servers', () {
    final mgr = container.read(connectionManagerProvider);
    expect(mgr.stateFor('nope'), SshConnectionState.disconnected);
  });

  test('connection manager connect on missing profile throws', () async {
    final mgr = container.read(connectionManagerProvider);
    await expectLater(
      mgr.connect('nope'),
      throwsA(isA<SshConnectionException>()),
    );
    expect(mgr.stateFor('nope'), SshConnectionState.error);
  });
}
