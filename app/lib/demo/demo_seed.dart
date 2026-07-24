import '../features/meeting_notes.dart';
import '../native/generated/signals/signals.dart'
    show MemoryItem, MemorySearchItem;

/// The demo's working context.
///
/// Everything here describes work that lives in this repository and its
/// siblings — the Rust hub, the Cloudflare Worker, the nRF5340 pendant,
/// `crepuscularity`, `zkr`, `rx4`, `praefectus`, `alpenglow` — so the demo
/// reads like real engineering context without inventing a person to attach
/// it to. Every evidence `sourceId` cited by a current resolves to an entry
/// in [demoMemory] below; nothing points outside the seed.
///
/// The clock is relative to [demoNow] so the brief, the timings and the
/// meeting notes stay plausible however long this build is deployed.
DateTime demoNow() => DateTime.now();

DateTime _ago(Duration d) => demoNow().subtract(d);

DateTime _ahead(Duration d) => demoNow().add(d);

String _iso(DateTime value) => value.toUtc().toIso8601String();

/// A surfaced current, in the wire shape `/v1/currents` returns.
Map<String, Object?> _current({
  required String id,
  required String title,
  required String summary,
  required String reason,
  required String proposedNextStep,
  required double confidence,
  required List<(String, String)> evidence,
  String? sourceKind,
  Map<String, Object?>? metadata,
  Duration createdAgo = const Duration(hours: 3),
  Duration? expiresIn,
}) {
  final created = _ago(createdAgo);
  return {
    'id': id,
    'title': title,
    'summary': summary,
    'sourceKind': sourceKind,
    'metadata': ?metadata,
    'status': 'surfaced',
    'evidence': <Object?>[
      for (final (sourceId, why) in evidence)
        <String, Object?>{'sourceId': sourceId, 'reason': why},
    ],
    'reason': reason,
    'timing': <String, Object?>{
      'surfaceAt': _iso(created),
      if (expiresIn != null) 'expiresAt': _iso(_ahead(expiresIn)),
    },
    'confidence': confidence,
    'proposedNextStep': proposedNextStep,
    'createdAt': _iso(created),
    'updatedAt': _iso(created),
  };
}

/// The currents the demo's hub home shows, newest intent first.
List<Map<String, Object?>> demoCurrents() => [
  _current(
    id: 'current-pendant-ncs',
    title:
        'Pendant firmware is pinned to NCS 3.4.0 — the devkit targets are not',
    summary:
        'The CV1 image builds against NCS v3.4.0 in the Nordic toolchain '
        'container. The nRF52840 devkit target still assumes the nrfx 2.x PDM '
        'API and does not build. Decide whether it is ported or dropped from '
        'the matrix before the next OTA.',
    sourceKind: 'firmware',
    reason:
        'Two build targets disagree about the SDK, and only one of them is '
        'covered by a build you actually run.',
    proposedNextStep:
        'Summarise what the nrfx 3.x PDM break means for devkit-v1 and draft '
        'the options.',
    confidence: 0.82,
    createdAgo: const Duration(hours: 5),
    evidence: const [
      (
        'source-firmware-readme',
        'The build matrix marks devkit-v1 as "does not build" under the '
            'nrfx 3.x PDM API break.',
      ),
      (
        'source-pm-static',
        'The static partition map had to be scoped to omi/nrf5340/cpuapp for '
            'v3.4.0 to accept it.',
      ),
    ],
  ),
  _current(
    id: 'current-rewind-dhash',
    title: 'Rewind capture policy: the dHash preview skip landed',
    summary:
        'Near-duplicate frames are dropped before the preview encode, so an '
        'idle screen stops writing frames at all. Worth confirming the '
        'threshold against a scrolling window before it is called settled.',
    sourceKind: 'rewind',
    reason:
        'The change is in and unverified — the policy it implements is the '
        'one thing in capture that is user-visible when it is wrong.',
    proposedNextStep:
        'Draft a short note on how the dHash threshold behaves on scrolling '
        'content.',
    confidence: 0.74,
    createdAgo: const Duration(hours: 9),
    evidence: const [
      (
        'source-rewind-policy',
        'Capture policy now compares a perceptual hash and skips the preview '
            'encode on a near-duplicate.',
      ),
    ],
  ),
  _current(
    id: 'current-worker-rs-cutover',
    title: 'worker-rs parity: decide the cutover order',
    summary:
        'The workers-rs port is cutover-ready and the TypeScript Worker is '
        'still the one deployed. Routes move one at a time or not at all; '
        'billing and channel delivery are the two that carry state.',
    sourceKind: 'worker',
    metadata: {
      'kind': 'decision',
      'title': 'Pick the first route to move to worker-rs',
      'detail': 'Auth and D1 reads first; billing last.',
    },
    reason:
        'Two implementations of the same surface exist and neither is being '
        'retired, which is the expensive state to sit in.',
    proposedNextStep:
        'List the Worker routes in the order they can safely move to '
        'worker-rs.',
    confidence: 0.69,
    createdAgo: const Duration(days: 1, hours: 2),
    evidence: const [
      (
        'source-worker-rs-note',
        'worker-rs is described as a cutover-ready parity port of the '
            'TypeScript Worker.',
      ),
      (
        'source-worker-routes',
        'Auth, D1 persistence, billing and channel delivery are the Worker\'s '
            'four responsibilities.',
      ),
    ],
  ),
  _current(
    id: 'current-crepus-brief',
    title: 'Crepuscularity renders the brief — keep the allowlist honest',
    summary:
        'The hub composes the hero brief as a `.crepus` document and the '
        'client refuses anything outside the node allowlist. That refusal is '
        'the security boundary, so the fallback path needs a test that fails '
        'loudly if it silently starts rendering.',
    sourceKind: 'crepuscularity',
    reason:
        'Model-authored UI is untrusted input, and the check that makes it '
        'safe currently fails open into the hand-built brief.',
    proposedNextStep:
        'Explain what the crepus allowlist rejects and where the fallback '
        'is covered.',
    confidence: 0.71,
    createdAgo: const Duration(days: 1, hours: 20),
    evidence: const [
      (
        'source-crepus-renderer',
        'A document that is blank, oversized, or references a node kind '
            'outside the allowlist is rejected before it draws.',
      ),
      (
        'source-crepus-readme',
        'One .crepus language drives GPUI, Ratatui, extensions, web and '
            'native mobile shells.',
      ),
    ],
  ),
  _current(
    id: 'current-zkr-corrections',
    title: 'zkr corrections supersede — check the mirror agrees',
    summary:
        'Claims in zkr keep both when they were true and when they were '
        'recorded, and a correction supersedes rather than rewrites. The '
        'client-side memory mirror should show the same history, not the '
        'latest value only.',
    sourceKind: 'memory',
    reason:
        'A mirror that flattens corrections quietly turns an auditable store '
        'into an unauditable one.',
    proposedNextStep:
        'Walk through what a correction looks like on the way from zkr to '
        'the memory mirror.',
    confidence: 0.66,
    createdAgo: const Duration(days: 2, hours: 4),
    evidence: const [
      (
        'source-zkr-principles',
        'Corrections supersede history instead of silently rewriting it.',
      ),
      (
        'source-memory-mirror',
        'The client mirror projects the exported memory event log.',
      ),
    ],
  ),
];

/// Meeting notes, most recent first.
List<MeetingNote> demoMeetingNotes() => [
  MeetingNote(
    id: 'demo-meeting-firmware',
    title: 'Pendant firmware sync',
    summary:
        'Agreed the CV1 image stays on NCS v3.4.0 for this OTA and the devkit '
        'targets come off the supported matrix until the nrfx 3.x PDM port is '
        'done. OTA stays on the MCUmgr Bluetooth transport.',
    startedAt: _ago(const Duration(hours: 6)),
    endedAt: _ago(const Duration(hours: 5, minutes: 25)),
    participants: const ['You', 'Firmware'],
    keyPoints: const [
      'CV1 builds inside the Nordic NCS v3.4.0 toolchain container.',
      'devkit-v1 is blocked on the nrfx 3.x PDM API change.',
      'The static partition map has to name omi/nrf5340/cpuapp explicitly.',
    ],
    decisions: const [
      'Ship the next OTA from the v3.4.0 CV1 image.',
      'Mark the nRF52840 devkit targets unsupported rather than half-working.',
    ],
    actions: const [
      'Write down what the PDM API break costs to port.',
      'Re-check the MCUboot OTA config after the partition rename.',
    ],
    markdown: '',
    metadataJson: '',
  ),
  MeetingNote(
    id: 'demo-meeting-memory',
    title: 'Memory and retrieval review',
    summary:
        'Went through how zkr keeps evidence authoritative and indexes '
        'disposable, and where rx4 sits in extraction and ranking. Retrieval '
        'packs stay bounded, tenant-scoped and cited.',
    startedAt: _ago(const Duration(days: 1, hours: 3)),
    endedAt: _ago(const Duration(days: 1, hours: 2, minutes: 10)),
    participants: const ['You', 'Memory'],
    keyPoints: const [
      'Sources and evidence are authoritative; embeddings are projections.',
      'Claims carry both valid time and recorded time.',
      'rx4 owns extraction and ranking above the store.',
    ],
    decisions: const [
      'Retrieval packs stay bounded and always carry citations.',
    ],
    actions: const ['Confirm the memory mirror preserves superseded claims.'],
    markdown: '',
    metadataJson: '',
  ),
  MeetingNote(
    id: 'demo-meeting-computer-use',
    title: 'Computer use and approvals',
    summary:
        'Praefectus keeps planning, identity and policy on the host; the model '
        'only proposes strict action requests. Dispatch is durable and '
        'at-most-once, and outcome_unknown is reported honestly rather than '
        'retried.',
    startedAt: _ago(const Duration(days: 2, hours: 5)),
    endedAt: _ago(const Duration(days: 2, hours: 4, minutes: 20)),
    participants: const ['You', 'Agent'],
    keyPoints: const [
      'One bounded Ed25519 AuthorityGrant per operation, verified before '
          'dispatch.',
      'Desktop and browser APIs are not transactional.',
    ],
    decisions: const [
      'Never auto-retry an operation that reported outcome_unknown.',
    ],
    actions: const [
      'Keep the approval step explicit in the hub, not implied by a setting.',
    ],
    markdown: '',
    metadataJson: '',
  ),
];

/// The conversation the demo opens with, oldest first.
const demoConversation = <({String role, String text})>[
  (role: 'user', text: 'What did we decide about the pendant firmware SDK?'),
  (
    role: 'assistant',
    text:
        'The CV1 image stays on NCS v3.4.0 for the next OTA. The nRF52840 '
        'devkit targets come off the supported matrix until the nrfx 3.x PDM '
        'API port is done — they were failing to build, not merely untested. '
        'The static partition map now names omi/nrf5340/cpuapp explicitly, '
        'because the unqualified filename stopped resolving in v3.4.0.',
  ),
  (role: 'user', text: 'And the plan for worker-rs?'),
  (
    role: 'assistant',
    text:
        'Nothing has moved yet. worker-rs is a cutover-ready parity port of '
        'the TypeScript Worker, so the open question is ordering rather than '
        'readiness: auth and the D1 reads are the cheap ones to move first, '
        'and billing and channel delivery carry state so they go last.',
  ),
  // The tour's opening turn. It is the newest message, so it is what a
  // visitor lands on, and it names the one thing they most need to know
  // before reading anything else on the screen.
  (
    role: 'assistant',
    text:
        'Welcome — I am Omi, and this is a guided walkthrough of my own hub. '
        'Everything here is sample data belonging to nobody, and it all runs '
        'in your browser. Ask me anything, or take the tour from the panel in '
        'the corner.',
  ),
];

/// Canned assistant replies, matched on keywords. The demo never reaches a
/// model — this map is the whole of what it can say, and [demoFallbackReply]
/// says so out loud rather than pretending otherwise.
const demoReplies = <(List<String>, String)>[
  (
    ['pendant', 'firmware', 'ncs', 'nrf', 'pdm', 'devkit'],
    'Pendant firmware builds against NCS v3.4.0 inside Nordic\'s toolchain '
        'container, for the omi/nrf5340/cpuapp board target. The nRF52840 '
        'devkit targets still assume the nrfx 2.x PDM API and do not build '
        'under 3.x, so they are excluded rather than shipped broken. OTA runs '
        'over the MCUmgr Bluetooth transport, and the static partition map has '
        'to be scoped to the board target by filename.\n\n'
        'Cited: firmware/README.md build matrix, the partition-map rename.',
  ),
  (
    ['worker', 'cloudflare', 'rust', 'cutover', 'd1'],
    'There are two Workers: the deployed TypeScript one (Bun, Hono, D1) and '
        'worker-rs, a cutover-ready parity port on workers-rs. The routes can '
        'move one at a time. Auth and the D1 read paths are stateless enough '
        'to go first; billing and channel delivery hold state and should go '
        'last, once the read paths have run in production for a while.',
  ),
  (
    ['memory', 'zkr', 'evidence', 'claim', 'citation', 'correction'],
    'Memory is zkr: source evidence is authoritative, claims are temporal — '
        'they record both when a fact was true and when it was recorded — and '
        'corrections supersede history rather than rewriting it. Embeddings '
        'and search indexes are projections that can be rebuilt from the '
        'stored evidence. Retrieval is bounded, tenant-scoped, and always '
        'cited, which is why every current on your hub carries its sources.',
  ),
  (
    ['rewind', 'capture', 'dhash', 'screen', 'frame'],
    'Rewind\'s capture policy compares a perceptual hash of each frame against '
        'the previous one and skips the preview encode when they are near '
        'duplicates, so an idle screen stops writing frames. The threshold is '
        'the part worth checking: scrolling content is where a hash-based skip '
        'is most likely to be either too eager or useless.',
  ),
  (
    ['crepus', 'crepuscularity', 'brief', 'render', 'ui'],
    'The hub composes the hero brief as a .crepus document and Crepuscularity '
        'renders it. Because a model authored it, the client treats it as '
        'untrusted input: a document that is blank, over the node or depth '
        'caps, or that references a node kind outside the allowlist is '
        'rejected, and the hand-built brief renders instead. That rejection is '
        'the security boundary, not a nicety.',
  ),
  (
    ['praefectus', 'computer use', 'approval', 'agent', 'action'],
    'Computer use goes through Praefectus. The model only proposes strict '
        'ActionRequest values; the host keeps planning, identity, approval, '
        'permissions and policy. The host signs one bounded Ed25519 '
        'AuthorityGrant per operation and Praefectus verifies it against a '
        'pinned issuer key before dispatching. Dispatch is durable and '
        'at-most-once — and when the outcome genuinely is not known, it says '
        'outcome_unknown rather than claiming a safe cancellation.',
  ),
  (
    ['alpenglow', 'linux', 'boot', 'musl', 'distro'],
    'Alpenglow is the musl Linux side project: dinit as init, Oil packages, an '
        'immutable rootfs loaded entirely into RAM from an erofs or squashfs '
        'image, with /home, package state and caches persisted on a '
        'bcachefs-backed /state. It boots to login in under a second on '
        'native virtualisation.',
  ),
  (
    ['architecture', 'omi', 'how does', 'overview', 'stack'],
    'Omi is one Flutter client over a Rust hub. The hub (Rinf-bridged) does '
        'assistant dispatch and model-tier routing, Gemini Live voice, the '
        'workspace scan, meetings, memory and computer use. A Cloudflare '
        'Worker handles auth, D1 persistence, billing and channel delivery. '
        'The pendant is an nRF5340 running the CV1 firmware image. Memory is '
        'zkr, extraction and ranking is rx4, computer use is Praefectus, and '
        'the brief is rendered by Crepuscularity.',
  ),
];

const demoFallbackReply =
    'No model is running in this browser, so I am answering from a fixed set '
    'of notes: what Omi is, the brief, currents, memory and citations, '
    'meetings, the pendant, and settings — plus how it is built, from the '
    'pendant firmware and the Worker to zkr memory, Rewind capture, '
    'Crepuscularity, Praefectus and Alpenglow. '
    'Nothing you type here leaves your browser. Open Omi for the real '
    'assistant.';

String demoReplyFor(String prompt) {
  final text = prompt.toLowerCase();
  for (final (keywords, reply) in demoReplies) {
    for (final keyword in keywords) {
      if (text.contains(keyword)) return reply;
    }
  }
  return demoFallbackReply;
}

/// The memory the seeded currents cite. Every `sourceId` in [demoCurrents]
/// appears here, so following a citation lands somewhere real.
List<MemorySearchItem> demoMemory() => [
  for (final (id, excerpt, score) in _memoryRows)
    MemorySearchItem(
      kind: 'claim',
      id: id,
      excerpt: excerpt,
      relevanceBasisPoints: score,
      evidenceIds: [id],
    ),
];

List<MemoryItem> demoMemoryItems() => [
  for (final (id, excerpt, _) in _memoryRows)
    MemoryItem(
      kind: 'claim',
      id: id,
      title: excerpt.split('.').first,
      body: excerpt,
      recordedAtMs: _ago(const Duration(days: 2)).millisecondsSinceEpoch,
      evidenceIds: [id],
    ),
];

const _memoryRows = <(String, String, int)>[
  (
    'source-firmware-readme',
    'The firmware build matrix lists omi-cv1 on omi/nrf5340/cpuapp as the '
        'shipping target and marks devkit-v1 as not building, because of the '
        'nrfx 3.x PDM API break.',
    9200,
  ),
  (
    'source-pm-static',
    'Under NCS v3.4.0 the static partition map only resolves when the '
        'filename is scoped to the omi/nrf5340/cpuapp board target.',
    8600,
  ),
  (
    'source-rewind-policy',
    'Rewind capture policy compares a perceptual hash between frames and '
        'skips the preview encode on a near-duplicate.',
    8800,
  ),
  (
    'source-worker-rs-note',
    'worker-rs is a Rust/workers-rs parity port of the Cloudflare Worker, '
        'described as cutover-ready.',
    8400,
  ),
  (
    'source-worker-routes',
    'The Cloudflare Worker owns auth, D1 persistence, billing and channel '
        'delivery.',
    8100,
  ),
  (
    'source-crepus-renderer',
    'The crepus brief renderer rejects a document that is blank, over its '
        'node or depth caps, or that references a node kind outside the '
        'allowlist, and falls back to the hand-built brief.',
    8700,
  ),
  (
    'source-crepus-readme',
    'Crepuscularity compiles one .crepus template language to GPUI desktop, '
        'Ratatui terminal, browser extensions, web output and native mobile '
        'shells.',
    7900,
  ),
  (
    'source-zkr-principles',
    'In zkr, sources and evidence are authoritative, indexes are disposable, '
        'and corrections supersede history instead of rewriting it.',
    9000,
  ),
  (
    'source-memory-mirror',
    'The client-side memory mirror is a projection of the exported memory '
        'event log and can be rebuilt from it.',
    7700,
  ),
];

/// Search is seeded, not indexed: it ranks the fixed rows by word overlap so
/// the results move with the query without anything being computed remotely.
List<MemorySearchItem> demoMemorySearch(String query, int limit) {
  final terms = query
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((term) => term.length > 2)
      .toSet();
  if (terms.isEmpty) return demoMemory().take(limit).toList();
  final scored = <(MemorySearchItem, int)>[];
  for (final item in demoMemory()) {
    final haystack = '${item.id} ${item.excerpt}'.toLowerCase();
    final hits = terms.where(haystack.contains).length;
    if (hits > 0) scored.add((item, hits));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (item, _) in scored.take(limit)) item];
}

const demoMemoryGaps = <String>[];

/// Preferences the demo starts from. Installed into an in-memory
/// shared_preferences store, so the demo writes nothing to the browser's
/// localStorage and leaves nothing behind when the tab closes.
Map<String, Object> demoPreferences() => {
  'onboarding_complete_v1_local': true,
  'omi_local_profile_name': 'Alex',
  'hub_setup_omi_complete_v1': true,
  'hub_byok_hint_dismissed_v1': true,
};
