// Throwaway projects on disk for tests.
import 'dart:io';

import 'package:test/test.dart';

/// A fresh folder, deleted when the test ends.
Directory tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Writes [files] (path → text) under [root].
void writeFiles(Directory root, Map<String, String> files) {
  for (final e in files.entries) {
    File('${root.path}/${e.key}')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(e.value);
  }
}

/// A minimal pubspec for package [name].
String pubspecOf(String name, {String version = '1.0.0', String extra = ''}) =>
    'name: $name\nversion: $version\nenvironment:\n  sdk: ^3.0.0\n$extra';

/// Runs the Dart running these tests with [args] in [dir].
Future<ProcessResult> runDart(List<String> args, Directory dir) =>
    Process.run(Platform.resolvedExecutable, args, workingDirectory: dir.path);
