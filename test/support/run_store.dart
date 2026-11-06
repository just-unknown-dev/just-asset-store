/// Runs `just store …` in-process, answering yes to every question.
library;

import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:just_core_cli/just_core_cli.dart';

/// `just store [args]` in [cwd]: its exit code, output and errors.
Future<(int, String, String)> store(List<String> args, {String? cwd}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runJustPlugin(
    ['store', ...args],
    [StoreCommand()],
    context: JustContext(
      workingDirectory: cwd ?? Directory.current.path,
      out: out,
      err: err,
      readLine: () => 'y',
      interactive: true,
      environment: const {},
    ),
  );
  return (code, '$out', '$err');
}
