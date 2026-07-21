import '../api/worker_http.dart';
import 'currents_client.dart';

final class WorkerCurrentsTransport implements CurrentsTransport {
  const WorkerCurrentsTransport(this._client);

  final WorkerHttpClient _client;

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    final response = await _client.send(
      method: request.method.name.toUpperCase(),
      path: request.path,
      body: request.body,
    );
    return CurrentsResponse(
      statusCode: response.statusCode,
      body: response.body,
    );
  }
}
