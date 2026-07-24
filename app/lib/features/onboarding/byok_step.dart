import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/byok_client.dart';
import '../../native/generated/signals/signals.dart' show AssistantProvider;
import '../../providers/openai_oauth.dart';
import '../../providers/provider_credentials.dart';
import '../../providers/provider_models.dart';
import '../../providers/xai_oauth.dart';
import '../../ui/omi_ui.dart';

const _cream = Color(0xfffffcec);
const _ink = Color(0xff171716);
const _muted = Color(0x99fffcec);

const _title = TextStyle(
  color: _cream,
  fontFamily: OmiFonts.sans,
  fontSize: 38,
  fontWeight: FontWeight.w500,
  height: 1.2,
  letterSpacing: -1.2,
);
const _prose = TextStyle(
  color: _cream,
  fontFamily: OmiFonts.sans,
  fontSize: 20,
  fontWeight: FontWeight.w500,
  height: 1.5,
  letterSpacing: -.3,
);
const _quiet = TextStyle(
  color: _muted,
  fontFamily: OmiFonts.sans,
  fontSize: 15,
  fontWeight: FontWeight.w500,
  height: 1.4,
);

/// Onboarding step for bringing your own AI key, and — once a key is
/// connected — negotiating the BYOK subscription price with Omi.
///
/// The price shown here is whatever the worker last said it is. Nothing in
/// this widget computes, proposes, or remembers a price: it renders
/// [ByokClient] responses and settles by asking the worker to accept the
/// negotiation it already holds.
class OnboardingByokStep extends StatefulWidget {
  const OnboardingByokStep({
    required this.client,
    required this.onConnect,
    required this.onFinish,
    this.xaiOAuth,
    this.openAiOAuth,
    this.launch = launchUrl,
    super.key,
  });

  final ByokClient? client;

  /// Injected in tests so the sign-in flows can be driven without real network
  /// or a browser. Null falls back to the real clients.
  final XaiOAuthClient? xaiOAuth;
  final OpenAiOAuthClient? openAiOAuth;
  final Future<bool> Function(Uri, {LaunchMode mode}) launch;

  /// Stores the key and points inference at the user's provider. Throwing
  /// keeps the step on the connect phase with the failure shown.
  final Future<void> Function(ProviderCredential credential) onConnect;

  final VoidCallback onFinish;

  @override
  State<OnboardingByokStep> createState() => _OnboardingByokStepState();
}

enum _Phase { connect, negotiate, settled }

class _OnboardingByokStepState extends State<OnboardingByokStep> {
  final _model = TextEditingController();
  final _secret = TextEditingController();
  final _endpoint = TextEditingController();
  final _message = TextEditingController();
  final _scroll = ScrollController();

  AssistantProvider _provider = AssistantProvider.openAi;
  _Phase _phase = _Phase.connect;
  bool _busy = false;
  String? _error;
  String? _xaiUserCode;

  ByokPlan? _plan;
  String? _sessionId;
  int? _priceCents;
  int _turnsRemaining = 0;
  final List<ByokNegotiationMessage> _transcript = [];

  @override
  void initState() {
    super.initState();
    _model.text = defaultBalancedModel[_provider] ?? '';
  }

  /// Switching provider re-seeds the model field, but only while it still
  /// holds a seeded value: a model the user typed themselves survives.
  void _selectProvider(AssistantProvider? value) {
    final next = value ?? _provider;
    setState(() {
      if (_model.text.trim().isEmpty ||
          _model.text == defaultBalancedModel[_provider]) {
        _model.text = defaultBalancedModel[next] ?? '';
      }
      _provider = next;
    });
  }

  @override
  void dispose() {
    _model.dispose();
    _secret.dispose();
    _endpoint.dispose();
    _message.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _reducedMotion => MediaQuery.disableAnimationsOf(context);

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
    await _afterConnected(
      ProviderCredential(
        provider: _provider,
        model: _model.text.trim(),
        credential: _secret.text,
        endpoint: _provider == AssistantProvider.compatible
            ? _endpoint.text.trim()
            : null,
      ),
    );
  });

  /// Stores [credential] and advances into the price phase, shared by the
  /// API-key and OAuth sign-in paths.
  Future<void> _afterConnected(ProviderCredential credential) async {
    await widget.onConnect(credential);
    final client = widget.client;
    if (client == null) {
      if (mounted) widget.onFinish();
      return;
    }
    final plan = await client.getPlan();
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _priceCents = plan.priceCents;
      _phase = plan.settled ? _Phase.settled : _Phase.negotiate;
    });
  }

  Future<void> _signInWithXai() => _run(() async {
    final oauth = widget.xaiOAuth ?? XaiOAuthClient();
    try {
      final (authorization, pkce) = await oauth.requestDeviceCode();
      if (!mounted) return;
      setState(() => _xaiUserCode = authorization.userCode);
      final target = authorization.verificationUriComplete.isNotEmpty
          ? authorization.verificationUriComplete
          : authorization.verificationUri;
      if (target.isNotEmpty) {
        await widget.launch(
          Uri.parse(target),
          mode: LaunchMode.externalApplication,
        );
      }
      final tokens = await oauth.pollForTokens(authorization, pkce);
      await _afterConnected(
        ProviderCredential(
          provider: AssistantProvider.xai,
          model: _oauthModelFor(AssistantProvider.xai),
          credential: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          expiresAt: tokens.expiresAt,
        ),
      );
    } finally {
      if (mounted) setState(() => _xaiUserCode = null);
    }
  });

  Future<void> _signInWithOpenAi() => _run(() async {
    final oauth = widget.openAiOAuth ?? OpenAiOAuthClient();
    final pending = await oauth.beginSignIn();
    await widget.launch(
      pending.authorizeUrl,
      mode: LaunchMode.externalApplication,
    );
    final tokens = await pending.tokens;
    await _afterConnected(
      ProviderCredential(
        provider: AssistantProvider.openAi,
        model: _oauthModelFor(AssistantProvider.openAi),
        credential: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt,
        endpoint: openAiCodexBaseUrl,
      ),
    );
  });

  /// The model an OAuth session seeds: whatever the user typed if they changed
  /// it, otherwise the provider's balanced default (a model both the OAuth and
  /// API-key surfaces serve).
  String _oauthModelFor(AssistantProvider provider) {
    final typed = _model.text.trim();
    if (typed.isNotEmpty && typed != defaultBalancedModel[_provider]) {
      return typed;
    }
    return defaultBalancedModel[provider] ?? typed;
  }

  Future<void> _startNegotiation() => _run(() async {
    final opening = await widget.client!.startNegotiation();
    if (!mounted) return;
    setState(() {
      _sessionId = opening.sessionId;
      _priceCents = opening.priceCents;
      _turnsRemaining = opening.turnsRemaining;
      _transcript
        ..clear()
        ..addAll(opening.transcript);
    });
  });

  Future<void> _send() {
    final message = _message.text.trim();
    final sessionId = _sessionId;
    if (message.isEmpty || sessionId == null) return Future.value();
    _message.clear();
    setState(
      () => _transcript.add(
        ByokNegotiationMessage(fromOmi: false, content: message),
      ),
    );
    return _run(() async {
      final turn = await widget.client!.send(sessionId, message);
      if (!mounted) return;
      setState(() {
        _transcript.add(
          ByokNegotiationMessage(fromOmi: true, content: turn.reply),
        );
        _priceCents = turn.priceCents;
        _turnsRemaining = turn.turnsRemaining;
      });
    });
  }

  Future<void> _accept() => _run(() async {
    final plan = await widget.client!.accept(_sessionId!);
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _priceCents = plan.priceCents;
      _phase = _Phase.settled;
    });
  });

  Future<void> _takeStandard() => _run(() async {
    final plan = await widget.client!.takeStandardPrice();
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _priceCents = plan.priceCents;
      _phase = _Phase.settled;
    });
  });

  Widget _field(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: key,
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(
        color: _cream,
        fontFamily: OmiFonts.sans,
        fontSize: 17,
      ),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        labelStyle: _quiet,
        enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: _muted),
        ),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: _cream),
        ),
      ),
    ),
  );

  Widget _primary(Key key, String label, VoidCallback? onPressed) =>
      FilledButton(
        key: key,
        onPressed: _busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: _cream,
          foregroundColor: _ink,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: OmiFonts.sans,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _secondary(Key key, String label, VoidCallback? onPressed) =>
      TextButton(
        key: key,
        onPressed: _busy ? null : onPressed,
        style: TextButton.styleFrom(foregroundColor: _muted),
        child: Text(
          label,
          style: const TextStyle(fontFamily: OmiFonts.sans, fontSize: 15),
        ),
      );

  Widget _priceCard() {
    final plan = _plan;
    final price = _priceCents;
    if (price == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        border: Border.all(color: _muted),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatPriceCents(price)} a month',
            key: const Key('byok_price'),
            style: _title.copyWith(fontSize: 30, letterSpacing: -.8),
          ),
          const SizedBox(height: 4),
          Text(
            plan != null && price < plan.standardPriceCents
                ? 'Down from ${formatPriceCents(plan.standardPriceCents)}. '
                      'You pay your own provider for inference.'
                : 'The standard price when you bring your own key.',
            style: _quiet,
          ),
        ],
      ),
    );
  }

  Widget _bubble(ByokNegotiationMessage message) => Align(
    alignment: message.fromOmi ? Alignment.centerLeft : Alignment.centerRight,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: const BoxConstraints(maxWidth: 460),
      decoration: BoxDecoration(
        color: message.fromOmi ? const Color(0x14fffcec) : _cream,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        message.content,
        style: TextStyle(
          color: message.fromOmi ? _cream : _ink,
          fontFamily: OmiFonts.sans,
          fontSize: 16,
          height: 1.4,
        ),
      ),
    ),
  );

  /// The "Sign in with…" affordance, shown only for the two providers that
  /// ship a sanctioned subscription OAuth flow. Every provider keeps the API
  /// key field below as the always-available path.
  List<Widget> _oauthAffordance() {
    final (label, onPressed, key) = switch (_provider) {
      AssistantProvider.xai => (
        'Sign in with xAI',
        _signInWithXai,
        const Key('byok_signin_xai'),
      ),
      AssistantProvider.openAi => (
        'Sign in with ChatGPT',
        _signInWithOpenAi,
        const Key('byok_signin_openai'),
      ),
      _ => (null, null, null),
    };
    if (label == null) return const [];
    return [
      const SizedBox(height: 8),
      _primary(key!, label, onPressed),
      if (_xaiUserCode != null) ...[
        const SizedBox(height: 8),
        Text(
          'Enter code $_xaiUserCode in your browser to finish.',
          key: const Key('byok_xai_code'),
          style: _quiet,
          textAlign: TextAlign.center,
        ),
      ],
      const SizedBox(height: 8),
      Text(
        _provider == AssistantProvider.xai
            ? 'Uses your SuperGrok or X Premium+ subscription. Or paste an '
                  'API key below.'
            : 'Uses your ChatGPT Plus or Pro subscription. Or paste an API '
                  'key below.',
        style: _quiet,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _connectPhase() => [
    const Text(
      'Bring your own AI.',
      style: _title,
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: 16),
    const Text(
      'Point Omi at your own provider and your key stays on this device. '
      'Omi then costs less, because you are paying for the inference.',
      style: _prose,
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: 28),
    DropdownButtonFormField<AssistantProvider>(
      key: const Key('byok_provider'),
      initialValue: _provider,
      dropdownColor: _ink,
      style: const TextStyle(color: _cream, fontFamily: 'Avenir Next'),
      decoration: InputDecoration(labelText: 'Provider', labelStyle: _quiet),
      items: [
        for (final value in AssistantProvider.values)
          if (value != AssistantProvider.worker)
            DropdownMenuItem(value: value, child: Text(value.name)),
      ],
      onChanged: _busy ? null : _selectProvider,
    ),
    const SizedBox(height: 12),
    _field('Model', _model, key: const Key('byok_model')),
    ..._oauthAffordance(),
    _field('API key', _secret, obscure: true, key: const Key('byok_key')),
    if (_provider == AssistantProvider.compatible)
      _field('HTTPS endpoint', _endpoint, key: const Key('byok_endpoint')),
    const SizedBox(height: 8),
    _primary(const Key('byok_connect'), 'Connect', _connect),
    _secondary(const Key('byok_skip_connect'), 'Not now', widget.onFinish),
  ];

  List<Widget> _negotiatePhase() {
    final plan = _plan;
    if (_sessionId == null) {
      return [
        const Text(
          'Now, about the price.',
          style: _title,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          plan == null
              ? 'Omi costs less when you bring your own key.'
              : 'Standard with your own key is '
                    '${formatPriceCents(plan.standardPriceCents)} a month. '
                    'If that is not right for you, say so and we will talk it '
                    'through. Take your time — the offer does not expire.',
          style: _prose,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _priceCard(),
        const SizedBox(height: 20),
        _primary(
          const Key('byok_negotiate'),
          'Talk about the price',
          plan?.negotiable == false ? null : _startNegotiation,
        ),
        _secondary(
          const Key('byok_take_standard'),
          'Keep the standard price',
          _takeStandard,
        ),
      ];
    }
    return [
      _priceCard(),
      const SizedBox(height: 20),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: ListView(
          key: const Key('byok_transcript'),
          controller: _scroll,
          shrinkWrap: true,
          children: [for (final message in _transcript) _bubble(message)],
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('byok_message'),
              controller: _message,
              enabled: !_busy && _turnsRemaining > 0,
              onSubmitted: (_) => _send(),
              style: const TextStyle(
                color: _cream,
                fontFamily: OmiFonts.sans,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: _turnsRemaining > 0
                    ? 'Make your case'
                    : 'That is as far as this conversation goes',
                hintStyle: _quiet,
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: _muted),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: _cream),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _primary(const Key('byok_send'), 'Send', _send),
        ],
      ),
      const SizedBox(height: 18),
      _primary(
        const Key('byok_accept'),
        _priceCents == null
            ? 'Agree'
            : 'Agree at ${formatPriceCents(_priceCents!)}',
        _accept,
      ),
      _secondary(
        const Key('byok_take_standard'),
        'Skip this and keep the standard price',
        _takeStandard,
      ),
    ];
  }

  List<Widget> _settledPhase() => [
    // Arriving here is the one moment in setup worth celebrating, so the mark
    // scatters and re-forms once as the phase settles.
    const Center(
      child: OmiActivityOrb(
        size: 40,
        color: _cream,
        state: OmiOrbState.success,
      ),
    ),
    const SizedBox(height: 20),
    const Text('Settled.', style: _title, textAlign: TextAlign.center),
    const SizedBox(height: 16),
    _priceCard(),
    const SizedBox(height: 20),
    _primary(const Key('byok_done'), 'Continue', widget.onFinish),
  ];

  @override
  Widget build(BuildContext context) {
    final children = switch (_phase) {
      _Phase.connect => _connectPhase(),
      _Phase.negotiate => _negotiatePhase(),
      _Phase.settled => _settledPhase(),
    };
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...children,
        if (_busy) ...[
          const SizedBox(height: 16),
          const Center(child: OmiActivityOrb.loading(size: 24, color: _cream)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(
            _error!,
            key: const Key('byok_error'),
            style: _quiet.copyWith(color: const Color(0xffffb4a6)),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
    // The phase change is the only motion in this step, and it is dropped
    // entirely when the platform asks for reduced motion.
    return _reducedMotion
        ? column
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: KeyedSubtree(key: ValueKey(_phase), child: column),
          );
  }
}
