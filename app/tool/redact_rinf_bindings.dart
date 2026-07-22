import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'usage: dart run tool/redact_rinf_bindings.dart <generated-dir>',
    );
    exitCode = 64;
    return;
  }

  final file = File('${arguments.single}/signals/command.dart');
  final source = file.readAsStringSync();
  const exposed = "'credential: \$credential'";
  const redacted = "'credential: [REDACTED]'";
  final matches = exposed.allMatches(source).length;
  final existingRedactions = redacted.allMatches(source).length;
  if (matches != 1 || existingRedactions != 0) {
    stderr.writeln(
      'expected exactly two generated credential debug fields; found '
      '$matches exposed and $existingRedactions redacted',
    );
    exitCode = 1;
    return;
  }
  file.writeAsStringSync(source.replaceAll(exposed, redacted));

  final transcriptionAuthFile = File(
    '${arguments.single}/signals/transcription_auth.dart',
  );
  var transcriptionAuthSource = transcriptionAuthFile.readAsStringSync();
  for (final field in ['firebaseToken', 'apiKey']) {
    final exposedAuth = "'$field: \$$field'";
    final redactedAuth = "'$field: [REDACTED]'";
    if (exposedAuth.allMatches(transcriptionAuthSource).length != 1 ||
        redactedAuth.allMatches(transcriptionAuthSource).isNotEmpty) {
      stderr.writeln('expected exactly one generated $field debug field');
      exitCode = 1;
      return;
    }
    transcriptionAuthSource = transcriptionAuthSource.replaceFirst(
      exposedAuth,
      redactedAuth,
    );
  }
  transcriptionAuthFile.writeAsStringSync(transcriptionAuthSource);

  final actionFile = File(
    '${arguments.single}/signals/computer_use_action.dart',
  );
  final actionSource = actionFile.readAsStringSync();
  const exposedText = "'text: \$text, '";
  const redactedText = "'text: [REDACTED], '";
  if (exposedText.allMatches(actionSource).length != 1 ||
      redactedText.allMatches(actionSource).isNotEmpty) {
    stderr.writeln('expected exactly one generated computer-use text field');
    exitCode = 1;
    return;
  }
  actionFile.writeAsStringSync(
    actionSource.replaceFirst(exposedText, redactedText),
  );

  final commandCaptureSource = file.readAsStringSync();
  const captureStartMarker = 'class CommandCaptureEvent extends Command {';
  final captureStart = commandCaptureSource.indexOf(captureStartMarker);
  final captureEnd = commandCaptureSource.indexOf('\n@immutable', captureStart);
  if (captureStart < 0 || captureEnd < 0) {
    stderr.writeln('expected exactly one generated capture class');
    exitCode = 1;
    return;
  }
  var captureSource = commandCaptureSource.substring(captureStart, captureEnd);
  for (final field in ['text', 'application', 'windowTitle']) {
    final exposedCapture = "'$field: \$$field, '";
    final redactedCapture = "'$field: [REDACTED], '";
    if (exposedCapture.allMatches(captureSource).length != 1 ||
        redactedCapture.allMatches(captureSource).isNotEmpty) {
      stderr.writeln('expected exactly one generated capture $field field');
      exitCode = 1;
      return;
    }
    captureSource = captureSource.replaceFirst(exposedCapture, redactedCapture);
  }
  file.writeAsStringSync(
    commandCaptureSource.replaceRange(captureStart, captureEnd, captureSource),
  );

  final commandMessageSource = file.readAsStringSync();
  const messageStartMarker = 'class CommandSendMessage extends Command {';
  final messageStart = commandMessageSource.indexOf(messageStartMarker);
  final messageEnd = commandMessageSource.indexOf('\n@immutable', messageStart);
  if (messageStart < 0 || messageEnd < 0) {
    stderr.writeln('expected exactly one generated send-message class');
    exitCode = 1;
    return;
  }
  final messageSource = commandMessageSource.substring(
    messageStart,
    messageEnd,
  );
  if (exposedText.allMatches(messageSource).length != 1 ||
      redactedText.allMatches(messageSource).isNotEmpty) {
    stderr.writeln('expected exactly one generated send-message text field');
    exitCode = 1;
    return;
  }
  file.writeAsStringSync(
    commandMessageSource.replaceRange(
      messageStart,
      messageEnd,
      messageSource.replaceFirst(exposedText, redactedText),
    ),
  );

  final commandCorrectionSource = file.readAsStringSync();
  const correctionStartMarker = 'class CommandCorrectMemory extends Command {';
  final correctionStart = commandCorrectionSource.indexOf(
    correctionStartMarker,
  );
  final correctionEnd = commandCorrectionSource.indexOf(
    '\n@immutable',
    correctionStart,
  );
  if (correctionStart < 0 || correctionEnd < 0) {
    stderr.writeln('expected exactly one generated correction class');
    exitCode = 1;
    return;
  }
  var correctionSource = commandCorrectionSource.substring(
    correctionStart,
    correctionEnd,
  );
  for (final field in ['text', 'value']) {
    final exposedCorrection = "'$field: \$$field, '";
    final redactedCorrection = "'$field: [REDACTED], '";
    if (exposedCorrection.allMatches(correctionSource).length != 1 ||
        redactedCorrection.allMatches(correctionSource).isNotEmpty) {
      stderr.writeln('expected exactly one generated correction $field field');
      exitCode = 1;
      return;
    }
    correctionSource = correctionSource.replaceFirst(
      exposedCorrection,
      redactedCorrection,
    );
  }
  file.writeAsStringSync(
    commandCorrectionSource.replaceRange(
      correctionStart,
      correctionEnd,
      correctionSource,
    ),
  );

  final transcriptFile = File(
    '${arguments.single}/signals/transcript_delta.dart',
  );
  final transcriptSource = transcriptFile.readAsStringSync();
  if (exposedText.allMatches(transcriptSource).length != 1 ||
      redactedText.allMatches(transcriptSource).isNotEmpty) {
    stderr.writeln('expected exactly one generated transcript text field');
    exitCode = 1;
    return;
  }
  transcriptFile.writeAsStringSync(
    transcriptSource.replaceFirst(exposedText, redactedText),
  );

  final assistantFile = File(
    '${arguments.single}/signals/assistant_delta.dart',
  );
  final assistantSource = assistantFile.readAsStringSync();
  if (exposedText.allMatches(assistantSource).length != 1 ||
      redactedText.allMatches(assistantSource).isNotEmpty) {
    stderr.writeln('expected exactly one generated assistant text field');
    exitCode = 1;
    return;
  }
  assistantFile.writeAsStringSync(
    assistantSource.replaceFirst(exposedText, redactedText),
  );

  for (final entry in {
    'memory_export_commit.dart': ['recordsJson'],
    'memory_item.dart': ['title', 'body'],
    'onboarding_scan_completed.dart': ['summary'],
  }.entries) {
    final memoryFile = File('${arguments.single}/signals/${entry.key}');
    var memorySource = memoryFile.readAsStringSync();
    for (final field in entry.value) {
      final exposedMemory = "'$field: \$$field'";
      final exposedMemoryWithComma = "'$field: \$$field, '";
      final redactedMemory = "'$field: [REDACTED]'";
      final redactedMemoryWithComma = "'$field: [REDACTED], '";
      if (exposedMemory.allMatches(memorySource).length == 1) {
        memorySource = memorySource.replaceFirst(exposedMemory, redactedMemory);
      } else if (exposedMemoryWithComma.allMatches(memorySource).length == 1) {
        memorySource = memorySource.replaceFirst(
          exposedMemoryWithComma,
          redactedMemoryWithComma,
        );
      } else {
        stderr.writeln('expected exactly one generated memory $field field');
        exitCode = 1;
        return;
      }
    }
    memoryFile.writeAsStringSync(memorySource);
  }
}
