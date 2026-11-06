/// `just store …`: the Asset Store's commands, as a just_core_cli plugin.
library;

import 'package:just_core_cli/just_core_cli.dart';

import 'creator_commands.dart';
import 'item_commands.dart';
import 'project_commands.dart';
import 'template_command.dart';

/// `just store`: install, update and remove Asset Store items, and the
/// creators' tools.
final class StoreCommand extends JustCommand {
  /// The command and all its subcommands.
  StoreCommand() {
    for (final c in <JustCommand>[
      InstallCommand(),
      UpdateCommand(),
      UninstallCommand(),
      ListCommand(),
      SearchCommand(),
      InfoCommand(),
      RestoreCommand(),
      GenerateCommand(),
      LinkCommand(),
      UnlinkCommand(),
      VendorCommand(),
      SourcesCommand(),
      CacheCommand(),
      PackCommand(),
      ValidateCommand(),
      IndexCommand(),
      TemplateCommand(),
    ]) {
      addSubcommand(c);
    }
  }

  @override
  String get name => 'store';

  @override
  String get description =>
      'Install, update and remove Asset Store items, and pack your own.';
}
