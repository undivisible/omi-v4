import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/providers/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('secure credentials remain UID scoped and deletable', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const store = SecureProviderCredentialStore();
    const credential = ProviderCredential(
      provider: AssistantProvider.xai,
      model: 'grok-4.5',
      credential: 'secret-key',
    );

    await store.write('user-a', credential);

    expect((await store.read('user-a'))?.model, 'grok-4.5');
    expect(await store.read('user-b'), isNull);
    await store.delete('user-a');
    expect(await store.read('user-a'), isNull);
  });

  test(
    'multiple providers store together and the newest routes first',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const store = SecureProviderCredentialStore();

      await store.write(
        'user-a',
        const ProviderCredential(
          provider: AssistantProvider.xai,
          model: 'grok-4.5',
          credential: 'xai-key',
        ),
      );
      await store.write(
        'user-a',
        const ProviderCredential(
          provider: AssistantProvider.openAi,
          model: 'gpt-5',
          credential: 'openai-key',
        ),
      );

      final all = await store.readAll('user-a');
      expect(all.map((value) => value.provider), [
        AssistantProvider.openAi,
        AssistantProvider.xai,
      ]);
      expect((await store.read('user-a'))?.provider, AssistantProvider.openAi);

      await store.remove('user-a', AssistantProvider.openAi);
      expect((await store.read('user-a'))?.provider, AssistantProvider.xai);
      await store.remove('user-a', AssistantProvider.xai);
      expect(await store.read('user-a'), isNull);
    },
  );

  test('legacy single-credential fields still read back', () async {
    FlutterSecureStorage.setMockInitialValues({
      'omi.ai.user-a.provider': 'anthropic',
      'omi.ai.user-a.model': 'claude-sonnet-5',
      'omi.ai.user-a.credential': 'legacy-key',
    });
    const store = SecureProviderCredentialStore();

    final all = await store.readAll('user-a');
    expect(all, hasLength(1));
    expect(all.single.provider, AssistantProvider.anthropic);
    expect(all.single.model, 'claude-sonnet-5');
  });

  test('compatible providers require a safe HTTPS endpoint', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const store = SecureProviderCredentialStore();

    await expectLater(
      store.write(
        'user-a',
        const ProviderCredential(
          provider: AssistantProvider.compatible,
          model: 'model',
          credential: 'secret-key',
          endpoint: 'http://models.example.test/v1',
        ),
      ),
      throwsArgumentError,
    );
  });
}
