import 'package:flutter_test/flutter_test.dart';
import 'package:omi/conversations/conversations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('appended messages survive a fresh store instance', () async {
    final store = PreferencesLocalConversationStore();
    await store.append(
      clientMessageId: 'chat-1',
      role: 'user',
      source: 'desktop',
      text: 'hello',
    );
    await store.append(
      clientMessageId: 'assistant:chat-1',
      role: 'assistant',
      source: 'desktop',
      text: 'hi there',
    );

    final relaunched = PreferencesLocalConversationStore();
    final replayed = await relaunched.replay(after: 0);

    expect(replayed, hasLength(2));
    expect(replayed.first.text, 'hello');
    expect(replayed.first.role, 'user');
    expect(replayed.last.text, 'hi there');
    expect(replayed.last.role, 'assistant');
    expect(replayed.last.cursor, greaterThan(replayed.first.cursor));
  });

  test('replay honours the after cursor', () async {
    final store = PreferencesLocalConversationStore();
    final first = await store.append(
      clientMessageId: 'chat-1',
      role: 'user',
      source: 'desktop',
      text: 'first',
    );
    await store.append(
      clientMessageId: 'chat-2',
      role: 'user',
      source: 'desktop',
      text: 'second',
    );

    final replayed = await store.replay(after: first.cursor);

    expect(replayed, hasLength(1));
    expect(replayed.single.text, 'second');
  });

  test('history is bounded to the configured capacity', () async {
    final store = PreferencesLocalConversationStore(capacity: 3);
    for (var index = 0; index < 5; index++) {
      await store.append(
        clientMessageId: 'chat-$index',
        role: 'user',
        source: 'desktop',
        text: 'message $index',
      );
    }

    final replayed = await store.replay(after: 0);

    expect(replayed, hasLength(3));
    expect(replayed.first.text, 'message 2');
    expect(replayed.last.text, 'message 4');
  });

  test('clear removes the persisted history', () async {
    final store = PreferencesLocalConversationStore();
    await store.append(
      clientMessageId: 'chat-1',
      role: 'user',
      source: 'desktop',
      text: 'hello',
    );
    await store.clear();

    expect(await store.replay(after: 0), isEmpty);
  });

  test('corrupt persisted history degrades to an empty replay', () async {
    SharedPreferences.setMockInitialValues({
      'local_conversation_v1': 'not json',
    });

    expect(await PreferencesLocalConversationStore().replay(after: 0), isEmpty);
  });
}
