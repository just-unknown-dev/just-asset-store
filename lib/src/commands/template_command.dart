/// `just store template`: a project template from the store, laid over a
/// project.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/just_core_cli.dart';

import '../catalog/item_manifest.dart';
import '../catalog/store_index.dart';
import '../install/planner.dart';
import '../project/store_project.dart';
import 'store_command.dart';

/// `just store template <id>[@<version>]`: a template item's `template/`
/// folder written over the project — its placeholders (`{{name}}`,
/// `{{title}}`, `{{App}}`) filled in for this project — and then the items it
/// depends on installed. `just create --template <id>` runs it on a new
/// project.
final class TemplateCommand extends StoreProjectCommand {
  /// The command and its options.
  TemplateCommand() {
    argParser.addFlag(
      'overwrite',
      negatable: false,
      help:
          "Write over the project's files where the template has its own "
          '(a new project, made to be replaced).',
    );
  }

  @override
  String get name => 'template';

  @override
  String get description =>
      "Lay a project template from the store over this project, and install "
      'what it needs.';

  @override
  String get invocation =>
      '${context.invokedAs} store template <id>[@<version>] [--overwrite]';

  @override
  Future<int> run() async {
    final arg = singleArgument('a template id');
    final parts = arg.split('@');
    final wanted = parts.length > 1 ? Version.tryParse(parts[1]) : null;
    if (parts.length > 2 || (parts.length > 1 && wanted == null)) {
      throw UsageFailure('"${parts.skip(1).join('@')}" is not a version.');
    }
    final project = storeProject;
    final store = storeFor(project);
    final loaded = await loadCatalog(store);
    final entry = loaded.catalog.entry(parts.first);
    if (entry == null) {
      throw CommandFailure('No template "${parts.first}" in the catalogs.');
    }
    final item = entry.item;
    if (item.kind != ItemKind.template) {
      throw CommandFailure(
        '${item.name} is not a template: install it with '
        '`${context.invokedAs} store install ${item.id}`.',
      );
    }
    if (item.unavailable) {
      throw CommandFailure(
        '${item.name} is no longer offered: its repository was removed or '
        'changed hands.',
      );
    }
    final version = wanted == null ? item.latest : item.versionOf(wanted);
    if (version == null) {
      throw CommandFailure('No such version of ${item.name}.');
    }
    if (!version.isAvailable) {
      throw CommandFailure(
        '${item.name} ${version.version} was '
        '${version.blocked ? 'taken down' : 'withdrawn by its publisher'}.',
      );
    }
    if (item.trust != TrustLevel.official) {
      output.warn(
        '${item.name} is code from ${item.author?.name ?? item.publisher} '
        '(${item.trust.name}). It will run with your permissions in the '
        'editor and the game: use it only if you trust its publisher.',
      );
    }
    final source = entry.source;
    if (source == null) {
      throw CommandFailure('Nowhere to download ${item.name} from.');
    }

    output.info('Downloading ${item.name} ${version.version}…');
    final bytes = await storeFailures(
      () => store.downloader.archive(source, item, version),
    );
    final zip = ZipArchive.read(bytes);
    final manifestEntry = zip.files
        .where((f) => f.path == ItemManifest.fileName)
        .firstOrNull;
    if (manifestEntry == null) {
      throw CommandFailure('${item.name} has no ${ItemManifest.fileName}.');
    }
    final manifest = ItemManifest.parse(
      utf8.decode(zip.contentOf(manifestEntry)),
    );
    final files = _files(zip, project.readText('pubspec.yaml') ?? '', project);
    if (files.isEmpty) {
      throw CommandFailure('${item.name} has no template/ folder.');
    }

    final conflicts = [
      for (final e in files.entries)
        if (project.file(e.key).existsSync() &&
            FileHashes.of(e.key, project.file(e.key).readAsBytesSync()) !=
                FileHashes.of(e.key, e.value))
          e.key,
    ];
    if (conflicts.isNotEmpty && !argResults!.flag('overwrite')) {
      throw CommandFailure(
        '${item.name} would write over ${conflicts.length} of the project\'s '
        'files: ${conflicts.take(8).join(', ')}'
        '${conflicts.length > 8 ? '…' : ''}. Pass --overwrite to replace them.',
      );
    }
    // What the template's game uses — kits, editor tools, art — planned at
    // the versions it asks for, with everything else, before anything is
    // written: then its files and those items go in as one change.
    final planner = await store.planner(catalog: loaded.catalog);
    final plan = planner.installAll(manifest.dependencies);
    output.line(
      'Laying ${item.name} ${version.version} over the project: '
      '${files.length} files'
      '${conflicts.isEmpty ? '' : ', ${conflicts.length} replaced'}.',
    );
    printPlan(plan);
    output.result = {...planJson(plan), 'template': item.id};
    if (plan.blockers.isNotEmpty) {
      throw CommandFailure(
        '${item.name} needs items that cannot be installed, so nothing was '
        'changed.',
      );
    }
    if (!confirm('Apply?')) return 1;

    final result = await storeFailures(
      () => store.installer().apply(
        plan,
        files: files,
        onProgress: (p) => output.info('  $p'),
      ),
    );
    await _markExecutable(project, zip, files.keys.toSet());
    for (final e in result.setupSnippets.entries) {
      output.line('\n${e.key} needs this in your game code:\n${e.value}');
    }
    output.result = {
      'template': item.id,
      'version': '${version.version}',
      'files': files.keys.toList(),
      'replaced': conflicts,
      'installed': [
        for (final c in plan.changes)
          if (c.kind == ChangeKind.install) c.id,
      ],
    };
    output.line('Done.');
    return 0;
  }

  /// Folders a template may not write into, anywhere in its tree: git's,
  /// the tools' scratch folders (journals that crash recovery replays) and
  /// the trash.
  static const Set<String> forbiddenFolders = {
    '.git',
    '.dart_tool',
    '.editor_trash',
    '.just_trash',
  };

  /// Files at the project's root a template may not write: what the store,
  /// `just` and pub keep — the lockfile, the project's plugin permissions,
  /// and pub's own files.
  static const Set<String> forbiddenFiles = {
    'just_store.lock.json',
    'just.json',
    'pubspec.lock',
    'pubspec_overrides.yaml',
    '.packages',
  };

  /// The archive's `template/` files, by project path, with the text ones'
  /// placeholders filled for the project whose pubspec is [pubspec].
  ///
  /// Throws [CommandFailure] when the template would write where the store,
  /// `just`, pub or git keep their own files. (Its scripts' executable bits
  /// are put back by [_markExecutable].)
  Map<String, Uint8List> _files(
    ZipArchive zip,
    String pubspec,
    StoreProject project,
  ) {
    final name =
        RegExp(
          r'^name:\s*(\S+)',
          multiLine: true,
        ).firstMatch(pubspec)?.group(1) ??
        'game';
    final title = project.readProjectFile().title;
    final names = ProjectNames(name, title: title);
    final out = <String, Uint8List>{};
    final refused = <String>[];
    for (final f in zip.files) {
      if (!f.path.startsWith('template/') || f.path.endsWith('/')) continue;
      final path = f.path.substring('template/'.length);
      final parts = path.toLowerCase().split('/');
      if (parts.any(forbiddenFolders.contains) ||
          (parts.length == 1 && forbiddenFiles.contains(parts.single))) {
        refused.add(path);
        continue;
      }
      final raw = zip.contentOf(f);
      if (!FileHashes.isText(path)) {
        out[path] = raw;
        continue;
      }
      final text = utf8
          .decode(raw)
          .replaceAll('{{name}}', names.name)
          .replaceAll('{{title}}', names.title)
          .replaceAll('{{App}}', names.app);
      out[path] = Uint8List.fromList(utf8.encode(text));
    }
    if (refused.isNotEmpty) {
      throw CommandFailure(
        'The template would write where the store, `just`, pub or git keep '
        'their own files, so nothing was changed: '
        '${refused.take(8).join(', ')}${refused.length > 8 ? '…' : ''}.',
      );
    }
    return out;
  }

  /// Makes the [written] files that were executable when the template was
  /// packed (shell scripts, say) executable again. Windows has no such bit.
  Future<void> _markExecutable(
    StoreProject project,
    ZipArchive zip,
    Set<String> written,
  ) async {
    if (Platform.isWindows) return;
    final paths = [
      for (final f in zip.files)
        if (f.isExecutable &&
            f.path.startsWith('template/') &&
            written.contains(f.path.substring('template/'.length)))
          project.file(f.path.substring('template/'.length)).path,
    ];
    if (paths.isEmpty) return;
    final result = await Process.run('chmod', ['+x', ...paths]);
    if (result.exitCode != 0) {
      final why = '${result.stderr}'.trim();
      output.warn('Could not make ${paths.length} script(s) executable: $why');
    }
  }
}
