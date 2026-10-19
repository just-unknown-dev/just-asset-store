// The Asset Store's commands for `just`: `just store ...`, `just add` and
// `just remove`. Not a tool of its own: `just` runs this with
// `dart run just_asset_store:just_plugin`.

import 'dart:io';

import 'package:just_asset_store/just_asset_store.dart';
import 'package:just_core_cli/just_core_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runJustPlugin(arguments, [StoreCommand()]);
}
