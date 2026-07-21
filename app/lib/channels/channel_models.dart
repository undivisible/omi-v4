typedef ChannelJson = Map<String, Object?>;

enum ChannelProvider {
  telegram,
  blooio;

  static ChannelProvider fromJson(Object? value) => switch (value) {
    'telegram' => ChannelProvider.telegram,
    'blooio' => ChannelProvider.blooio,
    _ => throw ChannelFormatException('unknown channel: $value'),
  };
}

enum ChannelLinkPhase {
  unlinked,
  requesting,
  awaitingConfirmation,
  linked,
  unlinking,
  failed,
}

final class ChannelFormatException implements Exception {
  const ChannelFormatException(this.message);

  final String message;

  @override
  String toString() => 'ChannelFormatException: $message';
}

final class ChannelLinkToken {
  const ChannelLinkToken({
    required this.channel,
    required this.token,
    required this.expiresAt,
  });

  factory ChannelLinkToken.fromJson(ChannelJson json) {
    final channel = ChannelProvider.fromJson(json['channel']);
    final token = json['token'];
    final expiresAt = json['expiresAt'];
    if (token is! String || token.trim().isEmpty) {
      throw const ChannelFormatException('token must be a non-empty string');
    }
    if (expiresAt is! int || expiresAt <= 0) {
      throw const ChannelFormatException(
        'expiresAt must be a positive integer',
      );
    }
    return ChannelLinkToken(
      channel: channel,
      token: token,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true),
    );
  }

  final ChannelProvider channel;
  final String token;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.toUtc().isBefore(expiresAt);
}

final class LinkedChannelIdentity {
  const LinkedChannelIdentity({required this.channel});

  factory LinkedChannelIdentity.fromJson(ChannelJson json) =>
      LinkedChannelIdentity(channel: ChannelProvider.fromJson(json['channel']));

  final ChannelProvider channel;
}

final class ChannelLinkState {
  const ChannelLinkState._(this.phase, {this.token, this.error});

  const ChannelLinkState.unlinked() : this._(ChannelLinkPhase.unlinked);
  const ChannelLinkState.requesting() : this._(ChannelLinkPhase.requesting);
  const ChannelLinkState.awaitingConfirmation(ChannelLinkToken token)
    : this._(ChannelLinkPhase.awaitingConfirmation, token: token);
  const ChannelLinkState.linked() : this._(ChannelLinkPhase.linked);
  const ChannelLinkState.unlinking() : this._(ChannelLinkPhase.unlinking);
  const ChannelLinkState.failed(String error)
    : this._(ChannelLinkPhase.failed, error: error);

  final ChannelLinkPhase phase;
  final ChannelLinkToken? token;
  final String? error;

  bool get canRetry => phase == ChannelLinkPhase.failed;
}
