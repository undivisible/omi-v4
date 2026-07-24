# OAuth connectors

Omi desktop connects to third-party accounts with the OAuth 2.0
authorization-code flow and PKCE. There is no client secret anywhere in the
repository or the shipped bundle: a desktop app cannot keep one, so PKCE is the
only proof binding the token exchange to the browser round trip.

## What the user must supply

A **client ID** per connector. It is a public identifier, not a secret.

### Google

1. Open <https://console.cloud.google.com/apis/credentials>.
2. Enable the Gmail API and the Google Calendar API for the project.
3. Create credentials → OAuth client ID → application type **Desktop app**.
4. Copy the client ID (`…apps.googleusercontent.com`). Ignore the client
   secret — Omi neither needs nor accepts it.
5. Paste the client ID into Settings → Connections → Google → Connect.

Alternatively pass it at build time:
`flutter build macos --dart-define=OMI_OAUTH_CLIENT_ID_GOOGLE=…`.

While the OAuth consent screen is in testing, add each account as a test user;
Google expires refresh tokens for unverified apps after seven days, which the
app surfaces as "Reconnect needed" rather than retrying.

## Scopes requested

| Scope | Why |
| --- | --- |
| `gmail.readonly` | Read message metadata (subject, timestamps). Nothing writes mail. |
| `calendar.readonly` | Read upcoming events. Nothing creates or edits events. |
| `openid`, `userinfo.email` | Name the connected account in settings. |

Settings lists the scopes the provider actually granted, in plain language,
under "Show granted access".

## How it behaves

- **Redirect**: `http://127.0.0.1:<ephemeral port>/oauth/callback`, bound per
  attempt and torn down as soon as the redirect lands.
- **State**: random per attempt, compared before the code is exchanged. A
  mismatch discards the code (authorization-code injection defence).
- **Storage**: tokens live only in the platform keychain
  (`flutter_secure_storage`), UID-scoped. The client ID is the only connector
  value in preferences.
- **Refresh**: two minutes ahead of expiry. `invalid_grant` marks the
  connection reconnect-needed once and is never retried.
- **Disconnect**: calls the provider's revocation endpoint with the refresh
  token before forgetting locally. A failed revocation is reported, not hidden.

## Adding a connector

Add one `OAuthConnector` constant in `lib/integrations/oauth/oauth_connector.dart`,
register it in `oauthConnectors`, and (optionally) implement `OAuthReadPath`.
The flow, the keychain store, the refresh and revoke logic, and the settings
row are all connector-agnostic and need no change.

## Not in this change

Ingestion into memory. `OAuthReadPath.preview` is the seam: a coordinator like
`AppleEventKitImportCoordinator` would drain the same call into the hub, with
per-connector cursors and a dedupe key, plus a scheduled refresh.
