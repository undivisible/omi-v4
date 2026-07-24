/// Whether this build is the public demo.
///
/// Set with `--dart-define=OMI_DEMO=1` by `worker/scripts/build-hub.sh`, and
/// only ever true in that build. Everything the demo does is decided at
/// compile time from this constant, so a release binary that was not built
/// with the define carries no demo path at all — dart2js drops it.
/// Read as a string rather than with `bool.fromEnvironment`, which only
/// recognises the literal `true` and would silently ignore `OMI_DEMO=1`.
const _omiDemo = String.fromEnvironment('OMI_DEMO');

const bool omiDemoMode = _omiDemo == '1' || _omiDemo == 'true';

/// The person the seed belongs to. Named so the greeting, the brief and the
/// conversation all agree with each other.
const demoPersonName = 'Alex';

/// Where "Open Omi" sends a visitor who wants the real thing.
const demoSignInUrl = '/portal';
