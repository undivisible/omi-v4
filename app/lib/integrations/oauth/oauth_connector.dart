import 'package:flutter/foundation.dart';

/// One OAuth scope, paired with the plain-language sentence shown to the user
/// so the settings row never makes them decode a scope URL.
@immutable
final class OAuthScope {
  const OAuthScope({required this.value, required this.summary});

  /// The wire value sent in the `scope` parameter.
  final String value;

  /// What the scope allows, in words a person can check against.
  final String summary;
}

/// A provider Omi can connect to over the authorization-code flow with PKCE.
///
/// Everything provider specific lives in a descriptor value, so a second
/// connector is a new [OAuthConnector] constant plus a read path — no change to
/// the flow, the store, the refresh logic, or the settings UI.
@immutable
final class OAuthConnector {
  const OAuthConnector({
    required this.id,
    required this.displayName,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.scopes,
    required this.clientIdInstructions,
    this.revocationEndpoint,
    this.authorizationParameters = const {},
    this.clientIdHelpUrl,
    this.accountFieldName,
  });

  /// Stable storage key. Never change it for a shipped connector.
  final String id;

  final String displayName;

  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;

  /// Where a token is revoked at the provider. Connectors without one can only
  /// forget locally, which we say out loud in the UI rather than implying the
  /// grant is gone.
  final Uri? revocationEndpoint;

  /// Requested scopes, narrowest first.
  final List<OAuthScope> scopes;

  /// Extra authorization-request parameters (Google needs `access_type` and
  /// `prompt` to hand back a refresh token).
  final Map<String, String> authorizationParameters;

  /// How the user obtains a client id for this provider. Shown verbatim in the
  /// connect dialog — nothing is embedded in the bundle.
  final String clientIdInstructions;

  final Uri? clientIdHelpUrl;

  /// Token-response field carrying a human-readable account label, when the
  /// provider returns one.
  final String? accountFieldName;

  List<String> get scopeValues => [for (final scope in scopes) scope.value];

  String get scopeParameter => scopeValues.join(' ');

  bool get revocable => revocationEndpoint != null;
}

/// Google Workspace, read only.
///
/// `gmail.readonly` and `calendar.readonly` are the narrowest scopes that let
/// Omi read message metadata and upcoming events; nothing Omi does today
/// writes to either service, so no write scope is requested.
final googleOAuthConnector = OAuthConnector(
  id: 'google',
  displayName: 'Google',
  authorizationEndpoint: Uri.parse(
    'https://accounts.google.com/o/oauth2/v2/auth',
  ),
  tokenEndpoint: Uri.parse('https://oauth2.googleapis.com/token'),
  revocationEndpoint: Uri.parse('https://oauth2.googleapis.com/revoke'),
  scopes: const [
    OAuthScope(
      value: 'https://www.googleapis.com/auth/gmail.readonly',
      summary:
          'Read your Gmail messages and labels. Omi cannot send, '
          'delete, or change mail.',
    ),
    OAuthScope(
      value: 'https://www.googleapis.com/auth/calendar.readonly',
      summary:
          'Read your Google Calendar events. Omi cannot create, edit, '
          'or cancel anything.',
    ),
    OAuthScope(
      value: 'openid',
      summary: 'Identify which Google account is connected.',
    ),
    OAuthScope(
      value: 'https://www.googleapis.com/auth/userinfo.email',
      summary: 'Show the connected account address in settings.',
    ),
  ],
  authorizationParameters: const {
    // A desktop client only receives a refresh token when it asks for offline
    // access, and only on a consent screen it has not silently skipped.
    'access_type': 'offline',
    'prompt': 'consent',
  },
  clientIdInstructions:
      'In Google Cloud Console, create an OAuth client of type "Desktop app" '
      'and paste its client ID here. Omi never stores a client secret — the '
      'desktop flow uses PKCE instead, so no secret is needed or accepted.',
  clientIdHelpUrl: Uri.parse(
    'https://console.cloud.google.com/apis/credentials',
  ),
);

/// Every connector the app offers. Adding one here is the whole registration.
final oauthConnectors = <OAuthConnector>[googleOAuthConnector];

OAuthConnector? oauthConnectorById(String id) {
  for (final connector in oauthConnectors) {
    if (connector.id == id) return connector;
  }
  return null;
}
