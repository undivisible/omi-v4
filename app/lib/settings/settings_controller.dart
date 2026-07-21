import 'settings_client.dart';
import 'settings_models.dart';

sealed class SettingsState {
  const SettingsState();
}

final class SettingsInitial extends SettingsState {
  const SettingsInitial();
}

final class SettingsLoading extends SettingsState {
  const SettingsLoading();
}

final class SettingsReady extends SettingsState {
  const SettingsReady(this.snapshot);

  final SettingsSnapshot snapshot;
}

final class SettingsApplying extends SettingsState {
  const SettingsApplying(this.snapshot);

  final SettingsSnapshot snapshot;
}

final class SettingsConflict extends SettingsState {
  const SettingsConflict({required this.previous, required this.revision});

  final SettingsSnapshot previous;
  final int revision;
}

final class SettingsConfirmationRequired extends SettingsState {
  const SettingsConfirmationRequired({
    required this.previous,
    required this.patch,
    required this.scope,
  });

  final SettingsSnapshot previous;
  final SettingsPatch patch;
  final SettingsScope scope;
}

final class SettingsRestartRequired extends SettingsState {
  const SettingsRestartRequired(this.result);

  final SettingsChangeResult result;
}

final class SettingsFailure extends SettingsState {
  const SettingsFailure({required this.previous, required this.error});

  final SettingsSnapshot? previous;
  final SettingsClientException error;
}

final class SettingsController {
  SettingsController(this._client);

  final SettingsClient _client;

  SettingsState state = const SettingsInitial();

  Future<void> load() async {
    state = const SettingsLoading();
    try {
      state = SettingsReady(await _client.getSettings());
    } on SettingsClientException catch (error) {
      state = SettingsFailure(previous: null, error: error);
    }
  }

  Future<void> apply({
    required SettingsPatch patch,
    required SettingsScope scope,
    String? confirmationReceiptId,
  }) async {
    final current = state;
    final snapshot = switch (current) {
      SettingsReady(:final snapshot) => snapshot,
      SettingsConfirmationRequired(:final previous) => previous,
      _ => throw StateError('settings must be ready before applying a patch'),
    };
    state = SettingsApplying(snapshot);
    try {
      final result = await _client.changeSettings(
        expectedRevision: snapshot.revision,
        patch: patch,
        scope: scope,
        confirmationReceiptId: confirmationReceiptId,
      );
      if (result.restartRequired) {
        state = SettingsRestartRequired(result);
      } else {
        state = SettingsReady(
          SettingsSnapshot(
            settings: result.settings,
            revision: result.revision,
            effectivePolicy: result.effectivePolicy,
          ),
        );
      }
    } on SettingsConflictException catch (error) {
      state = SettingsConflict(previous: snapshot, revision: error.revision);
    } on SettingsConfirmationRequiredException {
      state = SettingsConfirmationRequired(
        previous: snapshot,
        patch: patch,
        scope: scope,
      );
    } on SettingsClientException catch (error) {
      state = SettingsFailure(previous: snapshot, error: error);
    }
  }
}
