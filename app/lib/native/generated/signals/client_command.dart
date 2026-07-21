// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

@immutable
class ClientCommand {
  const ClientCommand({required this.requestId, required this.command});

  static ClientCommand deserialize(BinaryDeserializer deserializer) {
    deserializer.increaseContainerDepth();
    final instance = ClientCommand(
      requestId: deserializer.deserializeString(),
      command: Command.deserialize(deserializer),
    );
    deserializer.decreaseContainerDepth();
    return instance;
  }

  static ClientCommand bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ClientCommand.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }

  final String requestId;
  final Command command;

  ClientCommand copyWith({String? requestId, Command? command}) {
    return ClientCommand(
      requestId: requestId ?? this.requestId,
      command: command ?? this.command,
    );
  }

  void serialize(BinarySerializer serializer) {
    serializer.increaseContainerDepth();
    serializer.serializeString(requestId);
    command.serialize(serializer);
    serializer.decreaseContainerDepth();
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;

    return other is ClientCommand &&
        requestId == other.requestId &&
        command == other.command;
  }

  @override
  int get hashCode => Object.hash(requestId, command);

  @override
  String toString() {
    String? fullString;

    assert(() {
      fullString =
          '$runtimeType('
          'requestId: $requestId, '
          'command: $command'
          ')';
      return true;
    }());

    return fullString ?? 'ClientCommand';
  }
}

extension ClientCommandDartSignalExt on ClientCommand {
  /// Sends the signal to Rust.
  /// Passing data from Rust to Dart involves a memory copy
  /// because Rust cannot own data managed by Dart's garbage collector.
  void sendSignalToRust() {
    final messageBytes = bincodeSerialize();
    final binary = Uint8List(0);
    sendDartSignal(
      'rinf_send_dart_signal_client_command',
      messageBytes,
      binary,
    );
  }
}
