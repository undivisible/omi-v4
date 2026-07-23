import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/api_keys_client.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/native/native_hub.dart';

final class FakeApiKeysClient implements ApiKeysClient {
  FakeApiKeysClient({this.listFailure});

  final Object? listFailure;
  final List<ApiKeySummary> keys = [];
  int minted = 0;

  @override
  Future<List<ApiKeySummary>> listKeys() async {
    if (listFailure != null) throw listFailure!;
    return List.of(keys);
  }

  @override
  Future<MintedApiKey> createKey({
    required String name,
    required List<ApiKeyScope> scopes,
  }) async {
    minted += 1;
    final summary = ApiKeySummary(
      id: 'key-$minted',
      name: name,
      prefix: 'omi_sk_0000000$minted',
      scopes: scopes,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    keys.insert(0, summary);
    return MintedApiKey(plaintext: 'omi_sk_secret_$minted', summary: summary);
  }

  @override
  Future<void> revokeKey(String id) async {
    keys.removeWhere((key) => key.id == id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppServices makeServices(ApiKeysClient apiKeys) {
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      apiKeys: apiKeys,
    );
    addTearDown(services.dispose);
    return services;
  }

  Widget host(AppServices services) => MaterialApp(
    home: SettingsScreen(
      services: services,
      initialSection: SettingsSection.developer,
    ),
  );

  Future<void> tapAt(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('api_keys_tile')));
    await tester.pumpAndSettle();
  }

  testWidgets('a minted key is shown once and never again', (tester) async {
    final client = FakeApiKeysClient();
    await tester.pumpWidget(host(makeServices(client)));
    await openDialog(tester);

    await tester.enterText(
      find.byKey(const Key('api_key_name_field')),
      'laptop-mcp',
    );
    await tapAt(tester, find.byKey(const Key('api_key_create')));

    expect(find.byKey(const Key('api_key_plaintext')), findsOneWidget);
    expect(find.text('omi_sk_secret_1'), findsOneWidget);
    expect(
      find.textContaining('shown once and cannot be retrieved'),
      findsOneWidget,
    );

    await tapAt(tester, find.byKey(const Key('api_key_dismiss')));
    expect(find.byKey(const Key('api_key_plaintext')), findsNothing);
    expect(find.text('omi_sk_secret_1'), findsNothing);

    // Reopening cannot resurrect it: the list only carries the public prefix.
    await tapAt(tester, find.text('Close'));
    await tester.tap(find.byKey(const Key('api_keys_tile')));
    await tester.pumpAndSettle();
    expect(find.text('omi_sk_secret_1'), findsNothing);
    expect(find.byKey(const Key('api_key_name_key-1')), findsOneWidget);
  });

  testWidgets('revoking removes the key from the list', (tester) async {
    final client = FakeApiKeysClient();
    await tester.pumpWidget(host(makeServices(client)));
    await openDialog(tester);
    await tester.enterText(find.byKey(const Key('api_key_name_field')), 'cron');
    await tapAt(tester, find.byKey(const Key('api_key_create')));
    expect(find.byKey(const Key('api_key_revoke_key-1')), findsOneWidget);

    await tapAt(tester, find.byKey(const Key('api_key_revoke_key-1')));

    expect(find.byKey(const Key('api_key_revoke_key-1')), findsNothing);
    expect(find.text('No active keys.'), findsOneWidget);
    expect(client.keys, isEmpty);
  });

  testWidgets('a transport failure is surfaced, not swallowed', (tester) async {
    final client = FakeApiKeysClient(
      listFailure: const WorkerAuthenticationException('Sign in is required'),
    );
    await tester.pumpWidget(host(makeServices(client)));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Could not load your keys: Sign in is required'),
      findsOneWidget,
    );
  });

  testWidgets('scopes are visible and selectable', (tester) async {
    final client = FakeApiKeysClient();
    await tester.pumpWidget(host(makeServices(client)));
    await openDialog(tester);

    for (final scope in ApiKeyScope.values) {
      expect(
        find.byKey(Key('api_key_scope_${scope.wireName}')),
        findsOneWidget,
      );
    }
    await tapAt(tester, find.byKey(const Key('api_key_scope_speech:write')));
    await tester.enterText(find.byKey(const Key('api_key_name_field')), 'read');
    await tapAt(tester, find.byKey(const Key('api_key_create')));

    expect(client.keys.single.scopes, isNot(contains(ApiKeyScope.speechWrite)));
    expect(client.keys.single.scopes, contains(ApiKeyScope.memoryRead));
  });

  testWidgets('the MCP endpoint and a copyable config are shown', (
    tester,
  ) async {
    await tester.pumpWidget(host(makeServices(FakeApiKeysClient())));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mcp_config_snippet')), findsOneWidget);
    expect(find.textContaining('/mcp'), findsWidgets);
    expect(find.byKey(const Key('mcp_config_copy')), findsOneWidget);
  });
}
