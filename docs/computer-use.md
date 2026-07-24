# Computer use

What the assistant can drive on the machine it is running on, and the chain a
proposed action has to survive before anything happens.

The short version: the model can propose exactly two actions, against exactly
one accessibility element it must name unambiguously; the proposal is bound to
that element before the user ever sees it; the user approves it once; the
approval is consumed server-side; and the executor re-derives and re-checks the
whole request before it moves. Any link that does not hold turns the action into
an error, never into a best effort.

Source: `app/native/hub/src/computer_use.rs`, the tool-call plumbing in
`runtime.rs`, and `approval.rs` for the gate itself
(see [`agent-harnesses.md`](./agent-harnesses.md#3-the-approval-gate)).

## 1. What it can drive

Two tools are offered to the provider, and only when the platform actually
supports them:

| Tool | Arguments | Effect |
| --- | --- | --- |
| `computer_invoke` | `target_name`, `background_only` | Invoke the accessible element with that exact name. |
| `computer_set_value` | `target_name`, `value`, `background_only` | Set the value of the editable accessible element with that exact name. |

There is no mouse, no key synthesis, no screenshot loop and no coordinate space.
Actions are addressed semantically, through the platform accessibility tree by
way of `praefectus`'s `NativeExecutor`, on macOS, Windows and Linux. On every
other target `computer_use::available()` is `false`, the tools are not attached
to the request at all, and an approval that would need them fails with
`computer_use_unavailable` rather than being quietly dropped.

`background_only` asks for the action to be delivered without bringing the
target forward. It is honoured only where the platform reports both a
`TargetAddressed` delivery route and `Guarded` background support for that
action; otherwise binding fails. The hub reports the platform's own capability
description — backend, session isolation, per-action delivery route and
background support, and which permissions have been granted — up to the client
rather than inferring it.

## 2. Validating what the provider returned

Provider output is untrusted input, and `runtime.rs` treats a malformed tool
call as a failed turn rather than something to repair.

* A `ToolCallStart` is rejected unless computer-use tools are actually active,
  the call id is 1–256 bytes of `[A-Za-z0-9_-]`, the tool name is one of the two
  above, and the call id has not already been seen in this stream.
* Arguments are deserialized into structs declared `#[serde(deny_unknown_fields)]`
  with every field required, so an extra or missing key fails rather than
  defaulting.
* The decoded action goes through `valid_action`: a target name that is empty
  or whitespace, or longer than 1024 bytes, is refused, and a value longer than
  16 KB is refused.
* A `ToolCallEnd` whose call id was never opened is an error, and a message that
  ends with an unclosed tool call is an error.

Every one of those paths produces the same terminal outcome — `assistant
provider returned an invalid computer-use tool call` — and ends the stream. The
proposal is given a `Destructive` risk and a five-minute time-to-live from the
moment it is built.

## 3. Binding before asking

A validated tool call is not yet a proposal. `computer_use::bind` runs first, on
a blocking thread under a cancellation token wired to the turn's:

1. The executor's capabilities are read, and the action's own capability entry
   must exist exactly once and be listed as supported.
2. A semantic observation of the accessibility tree is taken and validated
   against the current time, so a stale observation cannot be used.
3. The named element is looked up **by exact name**, and the match must be
   unique. Zero matches and two matches are the same answer:
   `TargetUnavailable`. There is no fuzzy matching and no "closest" element.
4. The action is routed against that observation and target, so an action the
   element cannot accept fails here rather than at execution.

What the user is then shown is bound to a specific element in a specific
observation generation of a specific window of a specific process — the
`ComputerUseTargetProvenance` carried on the proposal records the process id,
process generation, window id, element role and observation generation. The
proposal's expiry is reduced to the earlier of its own five minutes and the
observation's expiry, so an approval can never outlive the screen it was
describing.

`prepare` then computes the request that would be sent — protocol version,
operation id (a prefixed SHA-256 of the proposal id), subject (a prefixed
SHA-256 of the uid, never the uid itself), host session id, safety class derived from the proposal's risk,
and for a set-value action a `TargetValueHash` verification policy over the
SHA-256 of the value — and takes `normalized_action_hash` of it. That hash goes
on the proposal.

## 4. From approval to effect

An `ApproveOnce` for a proposal carrying a computer action does not execute it.
It has to clear four more checks:

1. **The registry decides it.** Uid and authority generation must match, the
   proposal must still be pending and unexpired, and computer use must be
   available with a ledger path configured; otherwise the decision is refused
   with a named error and nothing runs.
2. **A server-issued receipt must be present and must match.** The decision
   carries a `ComputerUseAuthorityReceipt`, and every field of it is checked
   against the prepared action: protocol version equal to
   `omi-current-authority-v1`, subject equal to the uid, proposal id, operation
   id and action hash equal to the prepared ones, risk equal to the proposal's,
   a lifetime of at most 60 seconds that has not elapsed, a well-formed
   execution id, receipt id and action hash, and a receipt token of 32–512
   `[A-Za-z0-9_-]` bytes. A decision with no receipt is refused; a receipt
   supplied for a non-computer decision is also refused.
3. **The receipt is consumed server-side.** The hub posts it to
   `/v1/currents/executions/{execution}/receipts/{receipt}/claim` on the trusted
   managed origin, after re-checking that the origin resolves to public
   addresses. Approval is therefore spent centrally: a receipt claimed once
   cannot be claimed again, so a replayed local decision cannot produce a second
   effect. A failed claim is classified rather than retried — cancelled before
   effect, expired before effect, or rejected — and the proposal is finished
   accordingly.
4. **The executor re-derives everything.** `computer_use::execute` rebuilds the
   request from the bound action, re-computes `normalized_action_hash` and
   refuses if it differs from the hash the user approved; refuses if the host
   session id has changed; refuses if the authority window has passed or extends
   beyond the bound target's own expiry. Only then is a grant signed with the
   process's Ed25519 key and handed to the `praefectus` engine, which verifies
   that signature against its own verifier and appends to an on-disk ledger —
   `praefectus/operations.jsonl`, beside the memory database.

The outcome comes back as one of six terminals and is recorded on the proposal:
`Succeeded`, `Rejected`, `Failed`, `CancelledBeforeEffect`,
`ExpiredBeforeEffect`, `OutcomeUnknown`. `OutcomeUnknown` is a distinct state on
purpose and is surfaced with the explicit instruction that it must not be
retried automatically: an action that may or may not have had an effect is not
the same as one that did not.

## 5. What capture will and will not record

Computer use never reads or records the screen; it drives named elements and
nothing else. Audio capture is a separate policy, in `capture_policy.rs`, with
three modes:

| Mode | Microphone | System audio |
| --- | --- | --- |
| `always` | on | on |
| `onlyDuringMeetings` (default) | only once a meeting has been *confirmed* | with the microphone |
| `never` | on | never requested |

Two details are load-bearing. The default mode requires both that the meeting
detector has actually observed a state and that a meeting is active — an
unobserved detector reads as "no meeting", so the failure mode of not knowing is
not capturing. And `never` does not disable the microphone: it keeps voice input
working while never asking the operating system for the system-audio tap, which
is the one that would pick up the other side of a call.

When system audio is captured, macOS writes a two-track WAV — channel 0 the
local microphone, channel 1 the process tap — so the two sides of a call are
separated at the source and speaker attribution is done by comparing short-term
energy rather than by running a diarization model over merged audio.

The local workspace scan is likewise not computer use: it reads files and, when
the client asks for them, Apple Notes and Mail, with the caps and the redaction
described in
[`agent-harnesses.md`](./agent-harnesses.md#4-evidence-and-self-improvement).
