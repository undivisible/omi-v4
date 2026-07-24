// ignore_for_file: type=lint, type=warning
part of 'signals.dart';

enum AssistantProvider { openAi, anthropic, gemini, xai, compatible, worker }

extension AssistantProviderExtension on AssistantProvider {
  static AssistantProvider deserialize(BinaryDeserializer deserializer) {
    final index = deserializer.deserializeVariantIndex();
    switch (index) {
      case 0:
        return AssistantProvider.openAi;
      case 1:
        return AssistantProvider.anthropic;
      case 2:
        return AssistantProvider.gemini;
      case 3:
        return AssistantProvider.xai;
      case 4:
        return AssistantProvider.compatible;
      case 5:
        return AssistantProvider.worker;
      default:
        throw Exception(
          'Unknown variant index for AssistantProvider: ' + index.toString(),
        );
    }
  }

  void serialize(BinarySerializer serializer) {
    switch (this) {
      case AssistantProvider.openAi:
        return serializer.serializeVariantIndex(0);
      case AssistantProvider.anthropic:
        return serializer.serializeVariantIndex(1);
      case AssistantProvider.gemini:
        return serializer.serializeVariantIndex(2);
      case AssistantProvider.xai:
        return serializer.serializeVariantIndex(3);
      case AssistantProvider.compatible:
        return serializer.serializeVariantIndex(4);
      case AssistantProvider.worker:
        return serializer.serializeVariantIndex(5);
    }
  }

  Uint8List bincodeSerialize() {
    final serializer = BincodeSerializer();
    serialize(serializer);
    return serializer.bytes;
  }

  static AssistantProvider bincodeDeserialize(Uint8List input) {
    final deserializer = BincodeDeserializer(input);
    final value = AssistantProviderExtension.deserialize(deserializer);
    if (deserializer.offset < input.length) {
      throw Exception('Some input bytes were not read');
    }
    return value;
  }
}
