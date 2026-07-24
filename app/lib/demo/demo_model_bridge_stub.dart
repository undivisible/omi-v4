/// What the browser reported about the models it can run.
///
/// [promptApi] is one of `unsupported`, `downloadable` or `ready`; [webgpu] is
/// true only when the machine passed every capability check *and* the
/// transformers.js runtime was vendored next to the demo.
class DemoModelProbe {
  const DemoModelProbe({
    this.promptApi = 'unsupported',
    this.webgpu = false,
    this.model = '',
    this.downloadMb = 0,
  });

  final String promptApi;
  final bool webgpu;
  final String model;
  final int downloadMb;
}

/// The off-web implementation. There is no browser here, so there is no model
/// and the demo runs on its scripted replies — which is what the macOS,
/// Windows and test builds see.
Future<DemoModelProbe> probeDemoModels() async => const DemoModelProbe();

Future<String> prepareDemoModel(
  String tier,
  void Function(int percent) onProgress,
) async => 'unsupported';

Stream<String> askDemoModel(String tier, String payloadJson) =>
    const Stream<String>.empty();

void cancelDemoModel() {}
