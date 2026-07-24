import 'package:flutter/foundation.dart';

/// A surface the tour can put in front of the visitor.
///
/// The tour is only worth anything if talking about a thing shows the thing,
/// so every step names one of these and the demo shell opens it as the step
/// begins.
enum DemoSurface {
  /// The hub itself: greeting, brief, currents, meeting notes, composer.
  hub,

  /// The full currents list, with evidence.
  currents,

  /// Seeded memory, with the claims the currents cite.
  memory,

  /// Meeting notes.
  meetings,

  /// The pendant simulation.
  pendant,

  /// Real settings — providers, API keys, MCP.
  settings,
}

/// One step of the walkthrough.
///
/// [prompt] is what gets typed into the composer when the visitor takes the
/// step, so the tour reads as a conversation they are having rather than a
/// slideshow playing at them. [reply] is what the scripted tier says;
/// [grounding] is what a real model is given to say it in its own words. The
/// two carry the same facts on purpose — the tour must be coherent either
/// way.
class DemoTourStep {
  const DemoTourStep({
    required this.id,
    required this.chip,
    required this.prompt,
    required this.surface,
    required this.reply,
    required this.grounding,
  });

  final String id;
  final String chip;
  final String prompt;
  final DemoSurface surface;
  final String reply;
  final String grounding;
}

/// The walkthrough's script and its position in it.
///
/// Nothing here traps the visitor: the steps are suggestions, they can be
/// taken out of order, and anything typed into the composer that does not
/// match a step is answered normally.
class DemoTour extends ChangeNotifier {
  DemoTour();

  static final DemoTour instance = DemoTour();

  final _visited = <String>{};

  /// The surface the tour last asked for. The demo shell watches this and
  /// opens or closes routes to match.
  final ValueNotifier<DemoSurface> surface = ValueNotifier(DemoSurface.hub);

  Set<String> get visited => _visited;

  bool get finished => _visited.length >= steps.length;

  /// The next step the visitor has not taken, or null once they have taken
  /// them all.
  DemoTourStep? get next {
    for (final step in steps) {
      if (!_visited.contains(step.id)) return step;
    }
    return null;
  }

  /// Resolves a composer message to a step. Exact chip text wins; otherwise a
  /// step claims the message when the visitor's own words land on its topic.
  DemoTourStep? match(String text) {
    final needle = text.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final step in steps) {
      if (step.prompt.toLowerCase() == needle) return step;
    }
    for (final step in steps) {
      for (final keyword in _keywords[step.id] ?? const <String>[]) {
        if (needle.contains(keyword)) return step;
      }
    }
    return null;
  }

  /// The step the visitor is on. The answer to it streams into the chat, so
  /// entering a step deliberately does *not* open its surface: a route pushed
  /// over the hub would hide the very answer the visitor asked for. The tour
  /// offers the surface once the answer is there, and they open it.
  DemoTourStep? lastStep;

  void enter(DemoTourStep step) {
    _visited.add(step.id);
    lastStep = step;
    notifyListeners();
  }

  /// Bumped on every request, so asking for a surface again after the visitor
  /// navigated away by hand still opens it.
  final ValueNotifier<int> surfaceRequests = ValueNotifier(0);

  void show(DemoSurface value) {
    surface.value = value;
    surfaceRequests.value += 1;
    notifyListeners();
  }

  void restart() {
    _visited.clear();
    lastStep = null;
    surface.value = DemoSurface.hub;
    notifyListeners();
  }

  static String surfaceLabel(DemoSurface surface) => switch (surface) {
    DemoSurface.hub => 'the hub',
    DemoSurface.currents => 'currents',
    DemoSurface.memory => 'memory',
    DemoSurface.meetings => 'meeting notes',
    DemoSurface.pendant => 'the pendant',
    DemoSurface.settings => 'settings',
  };

  @override
  void dispose() {
    surface.dispose();
    surfaceRequests.dispose();
    super.dispose();
  }

  static const _keywords = <String, List<String>>{
    'what-is-omi': ['what is omi', 'what does omi', 'tell me about omi'],
    'brief': ['brief', 'what matters', 'morning'],
    'currents': ['current', 'what should i do', 'suggestion'],
    'memory': ['memory', 'citation', 'evidence', 'how do you know'],
    'meetings': ['meeting', 'notes'],
    'pendant': ['pendant', 'hardware', 'device', 'wear'],
    'settings': ['settings', 'api key', 'mcp', 'byok', 'provider'],
    'real-thing': ['sign up', 'get omi', 'buy', 'real thing', 'try it'],
  };

  static const steps = <DemoTourStep>[
    DemoTourStep(
      id: 'what-is-omi',
      chip: 'What is Omi?',
      prompt: 'What is Omi?',
      surface: DemoSurface.hub,
      reply:
          'Omi is one place where the work you have already done stays '
          'reachable. It listens where you let it — a pendant, meetings, your '
          'screen — turns what it hears into evidence-backed memory, and '
          'raises the few things that actually need you. This hub is that '
          'surface. Everything on it is sample data.',
      grounding:
          'Omi is a personal AI that captures what the user hears and sees '
          '(pendant, meetings, screen), stores it as evidence-backed memory, '
          'and surfaces a small number of things that need attention. The hub '
          'is the main surface: a greeting, a brief, currents, meeting notes '
          'and a composer.',
    ),
    DemoTourStep(
      id: 'brief',
      chip: 'Show me the brief',
      prompt: 'Show me the brief',
      surface: DemoSurface.hub,
      reply:
          'The top of the hub is the brief: where the day stands, in one '
          'read. It is composed fresh rather than templated, and if the '
          'composed version fails its checks the plain hand-built one renders '
          'instead — a brief is never allowed to be wrong-looking.',
      grounding:
          'The brief sits at the top of the hub and summarises where the day '
          'stands. It is composed as a .crepus document and rendered by '
          'Crepuscularity; a document that fails validation is rejected and a '
          'hand-built brief renders instead.',
    ),
    DemoTourStep(
      id: 'currents',
      chip: 'What are currents?',
      prompt: 'What are currents?',
      surface: DemoSurface.currents,
      reply:
          'Currents are the short list of things worth your attention right '
          'now. Each one carries why it surfaced, a proposed next step, and '
          'the evidence behind it. You can dismiss or snooze any of them — go '
          'ahead, this list is yours for the session. Accepting one hands work '
          'to the desktop agent, which a browser demo has no way to do.',
      grounding:
          'Currents are surfaced items: title, summary, a reason it surfaced, '
          'a proposed next step, a confidence, and evidence citations. They '
          'can be dismissed or snoozed. Accepting one dispatches work to the '
          'desktop agent, which the browser demo cannot do.',
    ),
    DemoTourStep(
      id: 'memory',
      chip: 'How do you know that?',
      prompt: 'How do you know that?',
      surface: DemoSurface.memory,
      reply:
          'Because every claim points at its source. Memory here stores '
          'evidence first and claims second, each claim knowing both when it '
          'was true and when it was recorded. Corrections supersede history '
          'rather than overwriting it. The citations on those currents resolve '
          'to the claims on this screen — nothing is cited that is not here.',
      grounding:
          'Memory is evidence-first: sources are authoritative, claims are '
          'temporal (valid time and recorded time), corrections supersede '
          'rather than overwrite, and embeddings are rebuildable projections. '
          'Retrieval is bounded and always cited, so every citation resolves '
          'to a stored claim.',
    ),
    DemoTourStep(
      id: 'meetings',
      chip: 'What about meetings?',
      prompt: 'What about meetings?',
      surface: DemoSurface.meetings,
      reply:
          'Meetings become notes with key points, decisions and actions, and '
          'they land next to everything else rather than in a separate app. '
          'These three are seeded. Recording a real one needs the desktop app '
          'and a microphone, so the demo does not pretend to.',
      grounding:
          'Meetings are transcribed and summarised into notes with key '
          'points, decisions and actions, surfaced alongside currents on the '
          'hub. Live recording needs the desktop app; the browser demo shows '
          'seeded notes only.',
    ),
    DemoTourStep(
      id: 'pendant',
      chip: 'Show me the pendant',
      prompt: 'Show me the pendant',
      surface: DemoSurface.pendant,
      reply:
          'The pendant is the part you wear: an nRF5340 that streams audio '
          'over Bluetooth to your phone, which relays it to the hub. Blue LED '
          'while it is connected and idle, red while it is capturing, and the '
          'battery reports over standard BLE. What you are looking at is a '
          'simulation drawn in the page — there is no device paired to a '
          'browser.',
      grounding:
          'The pendant is an nRF5340 running the CV1 firmware, streaming '
          'audio over Bluetooth LE to the phone, which relays bounded chunks '
          'to the hub. The LED is blue when connected and idle and red while '
          'capturing; battery reports over the standard BLE service. The demo '
          'shows a drawn simulation, not a paired device.',
    ),
    DemoTourStep(
      id: 'settings',
      chip: 'Can I bring my own keys?',
      prompt: 'Can I bring my own keys?',
      surface: DemoSurface.settings,
      reply:
          'Yes. Under AI Providers you put in your own key and Omi routes '
          'through it instead of the managed tier. Under API & MCP you get an '
          'API key and an MCP endpoint, so your memory is reachable from any '
          'MCP client. These are the real settings screens — they just have no '
          'account behind them here.',
      grounding:
          'Settings has AI Providers, where a user supplies their own model '
          'key and Omi routes through it instead of the managed tier, and API '
          '& MCP, which issues an API key and an MCP endpoint so memory is '
          'reachable from any MCP client. In the demo these screens are real '
          'but have no account behind them.',
    ),
    DemoTourStep(
      id: 'real-thing',
      chip: 'How do I get the real thing?',
      prompt: 'How do I get the real thing?',
      surface: DemoSurface.hub,
      reply:
          'Open Omi from the banner at the top. The real app signs in, keeps '
          'your memory on your machine and in your account rather than in a '
          'page, and turns on the parts a browser cannot do: capture, the '
          'pendant, meetings, computer use. That is the end of the tour — ask '
          'me anything else you like.',
      grounding:
          'The real app is opened from the demo banner. It signs in and '
          'enables what the browser cannot: capture, the pendant, '
          'transcription, meetings and computer use.',
    ),
  ];
}

/// The facts a real model is given when the visitor asks something the tour
/// has no step for. Deliberately the same shape as a step's grounding.
const demoTourGrounding =
    'Omi is a personal AI. It captures what the user hears and sees through a '
    'pendant, meetings and screen capture, stores it as evidence-backed '
    'memory where every claim cites its source, and surfaces a few things '
    'worth attention (currents) alongside a daily brief. One Flutter client '
    'runs over a Rust hub; a Cloudflare Worker handles auth, persistence and '
    'billing. Users can bring their own model keys, and memory is reachable '
    'over an MCP endpoint. This is a public demo running entirely in the '
    'browser: the data is sample data, and capture, the pendant, '
    'transcription and computer use need the desktop app.';

/// The system prompt every real-model tier is given.
///
/// It is deliberately narrow. The model is guiding a product tour with the
/// facts it is handed, and is told to say when it does not know rather than
/// inventing product behaviour that does not exist.
String demoSystemPrompt(String grounding) =>
    'You are Omi, guiding a short product tour inside a public demo of the '
    'Omi hub running entirely in the visitor\'s browser. Answer in at most '
    'three short sentences, plainly, in the second person. Use only the facts '
    'below; if the visitor asks something they do not cover, say you do not '
    'know and suggest opening the real app. Never claim to have access to the '
    'visitor\'s own data — everything on screen is sample data.\n\nFacts:\n'
    '$grounding';
