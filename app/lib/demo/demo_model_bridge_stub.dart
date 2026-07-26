/// What the browser reported about the model it can run.
///
/// [promptApi] is one of `unsupported`, `downloadable` or `ready`.
class DemoModelProbe {
  const DemoModelProbe({this.promptApi = 'unsupported'});

  final String promptApi;
}

/// The off-web implementation. There is no browser here, so there is no model
/// and chat is unavailable — which is what the macOS, Windows and test builds
/// see.
Future<DemoModelProbe> probeDemoModels() async => const DemoModelProbe();

Future<String> prepareDemoModel(
  String tier,
  void Function(int percent) onProgress,
) async => 'unsupported';

Stream<String> askDemoModel(String tier, String payloadJson) =>
    const Stream<String>.empty();

void cancelDemoModel() {}

void resetDemoModel() {}
