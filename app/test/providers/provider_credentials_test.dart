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
