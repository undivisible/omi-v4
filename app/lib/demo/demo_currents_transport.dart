import '../currents/currents.dart';
import 'demo_seed.dart';

/// Serves `/v1/currents` out of [demoCurrents] instead of the Worker.
///
/// It is the real [CurrentsClient] above this — the same decoding, the same
/// validation, the same evidence requirements — so a seeded current that would
/// be rejected on the wire is rejected here too. Dismiss and snooze mutate the
/// in-memory list and nothing else; accept is refused, because accepting a
/// current hands an action to the desktop agent and the demo has no agent to
/// hand it to.
final class DemoCurrentsTransport implements CurrentsTransport {
  DemoCurrentsTransport() : _items = demoCurrents();

  final List<Map<String, Object?>> _items;

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    final path = request.path;
    if (path == '/v1/currents/generate') {
      return const CurrentsResponse(statusCode: 200, body: <String, Object?>{});
    }
    if (path == '/v1/currents') {
      return CurrentsResponse(
        statusCode: 200,
        body: <String, Object?>{'currents': List<Object?>.of(_items)},
      );
    }
    final feedback = RegExp(
      r'^/v1/currents/([^/]+)/feedback$',
    ).firstMatch(path);
    if (feedback != null) {
      final id = feedback.group(1);
      final index = _items.indexWhere((item) => item['id'] == id);
      if (index < 0) {
        return const CurrentsResponse(
          statusCode: 404,
          body: <String, Object?>{'error': 'No such current'},
        );
      }
      final kind = (request.body?['kind'] as String?) ?? 'dismissed';
      final item = Map<String, Object?>.of(_items.removeAt(index))
        ..['status'] = kind
        ..['feedbackReference'] = 'demo-feedback-$id';
      if (kind == 'snoozed') {
        final timing = Map<String, Object?>.of(
          item['timing']! as Map<String, Object?>,
        );
        timing['snoozedUntil'] = demoNow()
            .add(const Duration(hours: 4))
            .toUtc()
            .toIso8601String();
        item['timing'] = timing;
      }
      return CurrentsResponse(
        statusCode: 200,
        body: <String, Object?>{'current': item},
      );
    }
    return const CurrentsResponse(
      statusCode: 501,
      body: <String, Object?>{
        'error':
            'Acting on a current needs the desktop app — the demo has no '
            'agent to hand the action to.',
      },
    );
  }
}
