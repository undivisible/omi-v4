# Bring your own key

Omi can run its inference on your own model provider. The key stays on your
device, the app talks to your provider directly, and the subscription costs
less because you are paying for the inference.

There is no equivalent page in the upstream Omi documentation to port: as of
2026-07-23 `docs.omi.me` publishes no BYOK page — its sitemap lists none, and
the developer section covers API keys for calling Omi, not provider keys for
Omi to call out with. What follows is written against this implementation.

## 1. What you can point Omi at

| Provider | Needs | Credential |
| --- | --- | --- |
| OpenAI | model id | API key |
| Anthropic | model id | API key |
| Gemini | model id | API key |
| xAI | model id | API key |
| An OpenAI-compatible endpoint | model id, HTTPS endpoint | API key |
| Omi's managed worker | — | your account token |

The first five are bring-your-own-key. The sixth is the managed path and is
handled separately: it is not selectable in the onboarding provider list, it is
never written to the credential store, and its endpoint must equal the
configured managed origin exactly rather than merely being a valid URL.

`compatible` exists so that a provider we do not name — a gateway, a
self-hosted OpenAI-shaped server, a router — still works without a code change.
It is the only BYOK kind that requires an endpoint.

## 2. Where the key lives

On the device, in platform secure storage, and nowhere else.

`SecureProviderCredentialStore` (`app/lib/providers/provider_credentials.dart`)
writes through `flutter_secure_storage` under a key namespaced by the account id
(`omi.ai.<uid>.providers`). Credentials for several providers can be stored at
once; the first entry is the one inference is routed to, and the rest stay
available so switching providers does not mean re-entering a key. Removing the
last credential deletes the whole namespace, including the older single-provider
fields that predate the list.

The store validates before it writes, and again after it reads: a stored entry
must have a non-empty model and credential, must not be the managed worker, and
— for `compatible` — must carry an endpoint that is `https`, has a host, and has
no userinfo, query or fragment. A stored list that fails any of those is treated
as absent rather than repaired.

The key is never sent to Omi's servers. Nothing in the worker reads it, and no
managed route accepts one; the worker's own managed completions run on Omi's
credential, against Omi's budget.

## 3. What the hub does with it

`AssistantProviderConfig` in `app/native/hub/src/runtime.rs` is where a
credential becomes a dispatchable provider. `rs_ai` supplies the client —
`chatgpt()`, `claude()`, `gemini()`, `xai()`, or `compatible(endpoint)` — and
the credential is attached as the API key.

For the two kinds that carry an endpoint, the URL is validated before anything
connects, and the checks are refusals rather than normalisations:

* the scheme must be `https`;
* no username, password, query string or fragment may be present;
* the host must be a domain, not an IP literal;
* `localhost`, `*.localhost` and `*.local` are refused;
* for the managed worker specifically, the origin must appear in the configured
  allowlist, and the resulting base must equal the trusted managed origin's
  `/v1`.

Before each dispatch the endpoint is resolved and every address it resolves to
must be public — no loopback, private, link-local, unique-local, multicast or
broadcast address is accepted, including IPv4-mapped IPv6 forms. An endpoint
that resolves to nothing is refused too. This is what stops a "compatible
endpoint" from being used to make the app talk to something on the local
network.

If no provider is configured at all, the hub reports `no model provider is
configured` rather than silently falling back to a managed model.

### Per-tier models — landing, not yet documented here

The hub is gaining per-provider tier tables so a BYOK user's five chat-facing
tiers (speed, balanced, smart, multimodal, search) resolve to their provider's
own model ids instead of the single model collected at onboarding, with
per-tier environment overrides. That work is in flight in
`app/native/hub/src/byok_tier.rs` alongside provider-hosted web search, and it
is deliberately not described in detail here: this page documents behaviour that
has shipped. Until it lands, onboarding collects one model id and that model
serves the request.

## 4. The price is negotiated, and the client never carries it

Connecting a key changes what Omi costs, and the amount is settled by talking to
Omi about it rather than by picking a plan.

The band is server-side and is the only place a price exists
(`worker/src/byok-pricing.ts`): a standard price, a hard floor, a turn limit, a
cooldown, and a closed list of concessions with a value each — committing for a
year, paying for your own inference, being happy to be written about, being a
student, joining early and reporting bugs. Every value is environment-overridable,
and a misconfigured override is rejected rather than applied: a floor above the
standard price is refused, and an unknown concession code in the override JSON
is dropped rather than becoming a new lever.

The conversation itself (`worker/src/byok-negotiation.ts`) works like this:

1. `POST /v1/byok/negotiation` opens a session, closing any session already
   open for that account so a user cannot bank sessions and accept a stale one
   later. It is refused while a previous agreement is inside its cooldown, and
   rate-limited to three starts a day.
2. `POST /v1/byok/negotiation/{id}/message` sends one turn, up to 600
   characters, up to 24 an hour, up to the band's turn limit. The model is
   instructed that it does not set prices and may suggest **at most one**
   concession per reply, chosen from the codes the server sent it.
3. The server, not the model, turns that into money. A suggested code that is
   not in the band's table is ignored; a code already granted in this session
   cannot be granted twice; `priceForGrants` de-duplicates the grants, subtracts
   their values from the standard price and clamps the result into
   `[floor, standard]`. No combination of grants — including a forged or
   replayed list — can land below the floor.
4. The reply text is sanitized before it is shown. The model is told not to
   quote figures, but being told is not a control: any currency amount in the
   reply is replaced with the price the server computed and any percentage is
   replaced with "a bit", so the prose cannot disagree with the record.
5. `POST /v1/byok/negotiation/{id}/accept` recomputes the price from the stored
   grants rather than trusting anything in the request, so a replayed or edited
   accept settles at exactly the figure the conversation earned. Accepting a
   session that was superseded by a later agreement is refused rather than
   allowed to reset the cooldown.
6. `POST /v1/byok/plan/standard` takes the standard price, and is recorded like
   any other outcome — skipping is a first-class path, not a dead end.

The agreement row keeps the price, the outcome, the band it was struck under,
the granted codes and the full transcript, so a settled price is auditable
against the conversation that produced it. `agreedByokPrice` re-clamps on read as
well as on write, so a row written under an older, wider band cannot undercut the
band in force today.

The onboarding UI (`app/lib/features/onboarding/byok_step.dart`) renders these
responses and nothing more. It does not compute, propose, or remember a price;
it shows what the worker last said and settles by asking the worker to accept
the negotiation the worker already holds.

## 5. Checkout

`createCheckoutSession` (`worker/src/billing.ts`) reads the agreed figure
server-side and builds the Stripe Checkout Session from it. **No caller passes a
price in.** When the agreed price equals the configured recurring price, that
price id is used directly; when it differs, the configured price is read back
from Stripe and rebuilt as an inline `price_data` line item that keeps the same
product, currency, billing interval and interval count and changes only the
amount. Mutating calls carry an idempotency key derived from the logical
operation, so a retried checkout cannot create a second session or a second
customer, and a returning payer is matched to an existing Stripe customer by
email before Checkout is allowed to create another.
