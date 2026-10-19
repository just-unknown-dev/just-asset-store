/// `just store template`: a project template from the store, laid over a
/// project.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/just_core_cli.dart';
import 'package:just_core_cli/project.dart'
    show ProjectLock, ProjectNames, ProjectTransaction;

import '../catalog/item_manifest.dart';
import '../catalog/store_index.dart';
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
    final version = wanted == null ? item.latest : item.versionOf(wanted);
    if (version == null) {
      throw CommandFailure('No such version of ${item.name}.');
    }
    final source = entry.source;
    if (source == null) {
      throw CommandFailure('Nowhere to download ${item.name} from.');
    }

    output.info('Downloading ${item.name} ${version.version}…');
    final bytes = await store.downloader.archive(source, item, version);
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
    output.line(
      'Laying ${item.name} ${version.version} over the project: '
      '${files.length} files'
      '${conflicts.isEmpty ? '' : ', ${conflicts.length} replaced'}.',
    );
    if (!confirm('Apply?')) return 1;

    final lock = ProjectLock.acquire(project);
    try {
      ProjectTransaction.recover(
        project,
        trash: StoreProject.trash,
        trashRoot: StoreProject.trashRoot,
      );
      final txn = ProjectTransaction.begin(
        project,
        trash: StoreProject.trash,
        trashRoot: StoreProject.trashRoot,
      );
      try {
        files.forEach(txn.writeBytes);
        txn.commit();
      } on Object {
        txn.rollBack();
        rethrow;
      }
    } finally {
      lock.release();
    }
    await _markExecutable(project, zip);

    // What the template's game uses: kits, editor tools, art.
    for (final dep in manifest.dependencies.keys) {
      if (project.readLock().items.containsKey(dep)) continue;
      output.info('Installing $dep…');
      final fresh = await loadCatalog(store);
      final plan = (await store.planner(catalog: fresh.catalog)).install(dep);
      final code = await applyPlan(store, plan);
      if (code != 0) {
        throw CommandFailure('The template needs $dep, which did not install.');
      }
    }
    output.result = {
      'template': item.id,
      'version': '${version.version}',
      'files': files.keys.toList(),
      'replaced': conflicts,
      'installed': manifest.dependencies.keys.toList(),
    };
    output.line('Done.');
    return 0;
  }

  /// The archive's `template/` files, by project path, with the text ones'
  /// placeholders filled for the project whose pubspec is [pubspec].
  ///
  /// (Its scripts' executable bits are put back by [_markExecutable].)
  Map<String, Uint8List> _files(
    ZipArchive zip,
    String pubspec,
    StoreProject project,
  ) {
    final name =
        RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(pubspec)?.group(1) ??
        'game';
    final title = project.readProjectFile().title;
    final names = ProjectNames(name, title: title);
    final out = <String, Uint8List>{};
    for (final f in zip.files) {
      if (!f.path.startsWith('template/') || f.path.endsWith('/')) continue;
      final path = f.path.substring('template/'.length);
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
    return out;
  }

  /// Makes the template's files that were executable when it was packed
  /// (shell scripts, say) executable again. Windows has no such bit.
  Future<void> _markExecutable(StoreProject project, ZipArchive zip) async {
    if (Platform.isWindows) return;
    final paths = [
      for (final f in zip.files)
        if (f.isExecutable && f.path.startsWith('template/'))
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
