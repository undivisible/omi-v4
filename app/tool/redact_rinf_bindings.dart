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
      'expected exactly one generated credential debug field; found '
      '$matches exposed and $existingRedactions redacted',
    );
    exitCode = 1;
    return;
  }
  file.writeAsStringSync(source.replaceFirst(exposed, redacted));
}
