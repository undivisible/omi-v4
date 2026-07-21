# Omi v4

Omi v4 is a proactive thinking partner and second brain that remembers a person's life with evidence, notices what matters next, and carries out bounded tasks.

## Memory

**Source**:
A conversation, capture, message, file, screen observation, or integration record from which knowledge can be derived.
_Avoid_: Raw memory

**Evidence**:
A durable reference connecting a derived fact or recommendation to the Source that supports it.
_Avoid_: Citation blob

**Personal Memory**:
The person's canonical, correctable knowledge built from evidenced observations and explicit assertions.
_Avoid_: User context, agent memory

**Daily Review**:
A dated textual account of the day's important events, decisions, progress, unresolved commitments, and supporting Sources.
_Avoid_: Nightly memory, daily dump

**Recommendation Memory**:
The separate history of proactive candidates, their evidence, timing, feedback, and outcomes.
_Avoid_: Personal Memory, notification history

**Learned Preference**:
An evidenced, revisable statement about how the person wants Omi to behave.
_Avoid_: Setting, personality

**Skill**:
A reusable procedure Omi has learned for performing a kind of task, with confidence and review history.
_Avoid_: Personal Memory, preference

## Action

**Current**:
A time-sensitive recommendation explaining what matters now, why, and the next useful action.
_Avoid_: Notification, insight

**Task**:
A user-authorized goal with a start, completion condition, status, and audit trail.
_Avoid_: Tool call, Current

**Capability Lease**:
Temporary authority granted to a Task for specific effects, resources, and duration.
_Avoid_: Permission, auto-approve

**Setup Task**:
A Task that helps the person grant a permission, connect a service, link a channel, or complete product configuration.
_Avoid_: Onboarding step

## Identity

**Person**:
The human Omi remembers and assists across applications, devices, and channels.
_Avoid_: Account, Firebase user

**Channel Identity**:
A verified Telegram, Blooio, or application identity linked to the Person.
_Avoid_: User

**Device**:
A phone, computer, browser, or Omi hardware product linked to the Person with declared capabilities.
_Avoid_: Client
