// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum ApprovalDecision { approveOnce, reject }

extension ApprovalDecisionExtension on ApprovalDecision {
  static ApprovalDecision deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return ApprovalDecision.approveOnce;
      case 1:
        return ApprovalDecision.reject;
      default:
        throw Exception(
          'Unknown variant index for ApprovalDecision: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case ApprovalDecision.approveOnce:
        return serializer.serializeVariantIndex(0);
      case ApprovalDecision.reject:
        return serializer.serializeVariantIndex(1);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static ApprovalDecision bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = ApprovalDecisionExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
