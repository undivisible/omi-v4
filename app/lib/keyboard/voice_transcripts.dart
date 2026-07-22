import '../native/native_hub.dart';

Stream<String> finalVoiceTranscripts(Stream<NativeEvent> events) => events
    .map(
      (event) => switch (event) {
        NativeEventTranscriptDelta(:final value) when value.finalSegment =>
          value.text.trim(),
        NativeEventLiveVoiceTranscript(:final value) when value.finalSegment =>
          value.text.trim(),
        _ => '',
      },
    )
    .where((text) => text.isNotEmpty);
