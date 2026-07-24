// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum ActionRisk { reversible, external, destructive }

extension ActionRiskExtension on ActionRisk {
  static ActionRisk deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return ActionRisk.reversible;
      case 1:
        return ActionRisk.external;
      case 2:
        return ActionRisk.destructive;
      default:
        throw Exception(
          'Unknown variant index for ActionRisk: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case ActionRisk.reversible:
        return serializer.serializeVariantIndex(0);
      case ActionRisk.external:
        return serializer.serializeVariantIndex(1);
      case ActionRisk.destructive:
        return serializer.serializeVariantIndex(2);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static ActionRisk bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ActionRiskExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
