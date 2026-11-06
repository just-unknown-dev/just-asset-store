/// `just store restore`, `generate`, `link`, `unlink`, `vendor`,
/// `sources` and `cache`: the commands about the project and this
/// machine.
library;

import 'package:just_core_cli/fetch.dart';
import 'package:just_core_cli/just_core_cli.dart';
import 'package:meta/meta.dart';

import '../install/store_installer.dart';
import '../install/store_linker.dart';
import '../lockfile/store_lock.dart';
import '../project/store_registry.dart';
import '../sources/store_source.dart';
import 'store_project_command.dart';

/// `just store restore`.
@internal
final class RestoreCommand extends StoreProjectCommand {
  @override
  String get name => 'restore';

  @override
  String get description =>
      'Download installed items whose folders are missing.';

  @override
  Future<int> run() async {
    final store = storeFor(storeProject);
    final result = await storeFailures(
      () => store.restore(onProgress: (p) => output.info('$p')),
    );
    for (final id in result.restored) {
      output.line('Restored $id.');
    }
    for (final p in result.problems) {
      output.warn(p);
    }
    if (result.restored.isEmpty && result.problems.isEmpty) {
      output.line('Nothing is missing.');
    }
    output.result = {'restored': result.restored, 'problems': result.problems};
    return result.problems.isEmpty ? 0 : 1;
  }
}

/// `just store generate [--check]`.
@internal
final class GenerateCommand extends StoreProjectCommand {
  /// Rewrites, or checks, the generated registry files.
  GenerateCommand() : super(catalogs: false) {
    argParser.addFlag(
      'check',
      negatable: false,
      help: 'Change nothing; fail when they are out of date.',
    );
  }

  @override
  String get name => 'generate';

  @override
  String get description =>
      'Rewrite the generated registry files (lib/editor/store_modules.g.dart, '
      'lib/game/store_extensions.g.dart).';

  @override
  Future<int> run() async {
    final project = storeProject;
    if (argResults!.flag('check')) {
      final stale = StoreRegistry.outdated(project);
      output.result = {'outdated': stale};
      if (stale.isEmpty) {
        output.line('The generated files are up to date.');
        return 0;
      }
      throw CommandFailure(
        'Out of date: ${stale.join(', ')}. Run `${context.invokedAs} store '
        'generate` to fix.',
      );
    }
    final problems = <String>[];
    final written = await storeFailures(
      () async => StoreInstaller.withLockSync(
        project,
        () => StoreRegistry.write(project, problems: problems),
      ),
    );
    for (final p in problems) {
      output.warn(p);
    }
    output
      ..result = {'written': written, 'problems': problems}
      ..line(
        written.isEmpty
            ? 'Already up to date.'
            : 'Wrote ${written.join(', ')}.',
      );
    return problems.isEmpty ? 0 : 1;
  }
}

/// `just store link <folder>...`.
@internal
final class LinkCommand extends StoreProjectCommand {
  /// Records checkouts without moving them.
  LinkCommand() : super(catalogs: false);

  @override
  String get name => 'link';

  @override
  String get description =>
      'Record your own checkouts of store items: listed and registered, '
      'never moved or updated.';

  @override
  String get invocation => '${context.invokedAs} store link <folder>...';

  @override
  Future<int> run() async {
    if (rest.isEmpty) throw const UsageFailure('link needs folders.');
    final project = storeProject;
    final ids = await storeFailures(
      () async => StoreLinker.link(project, [for (final f in rest) here(f)]),
    );
    output
      ..result = {'linked': ids}
      ..line('Linked ${ids.join(', ')}.');
    return 0;
  }
}

/// `just store unlink <id>`.
@internal
final class UnlinkCommand extends StoreProjectCommand {
  /// Forgets a linked item.
  UnlinkCommand() : super(catalogs: false);

  @override
  String get name => 'unlink';

  @override
  String get description => 'Forget a linked item (its checkout stays).';

  @override
  String get invocation => '${context.invokedAs} store unlink <id>';

  @override
  Future<int> run() async {
    final id = singleArgument('an item id');
    final project = storeProject;
    if (!await storeFailures(() async => StoreLinker.unlink(project, id))) {
      throw CommandFailure('$id is not a linked item.');
    }
    output
      ..result = {'unlinked': id}
      ..line('Unlinked $id.');
    return 0;
  }
}

/// `just store vendor <id>...`.
@internal
final class VendorCommand extends StoreProjectCommand {
  @override
  String get name => 'vendor';

  @override
  String get description =>
      'Copy linked items into the project as installed items: editor tools '
      'and kits into plugins/{category}/{name}/, content into '
      'packages/{category}/{name}/ (in a copy of the project without '
      'overrides pointing at the checkouts).';

  @override
  String get invocation => '${context.invokedAs} store vendor <id>...';

  @override
  Future<int> run() async {
    if (rest.isEmpty) throw const UsageFailure('vendor needs item ids.');
    final project = storeProject;
    final store = storeFor(project);
    final result = await storeFailures(
      () => StoreLinker.vendor(project, rest, pub: store.pub),
    );
    for (final c in result.changes) {
      output.line('Vendored ${c.id} into ${c.path}.');
    }
    output.result = {
      'vendored': [
        for (final c in result.changes) {'id': c.id, 'path': c.path},
      ],
    };
    return 0;
  }
}

/// `just store sources [add <url> | remove <id|url>]`.
@internal
final class SourcesCommand extends StoreProjectCommand {
  /// Lists, adds and removes the project's catalogs.
  SourcesCommand() : super(catalogs: false);

  @override
  String get name => 'sources';

  @override
  String get description =>
      'List the catalogs this project reads, or add or remove one.';

  @override
  String get invocation =>
      '${context.invokedAs} store sources [add <url> | remove <id|url>]';

  @override
  Future<int> run() async {
    final project = storeProject;
    final lock = project.readLock();
    if (rest.isEmpty) {
      final shown = lock.sources.isEmpty
          ? [LockedSource(SourceConfig.officialId, SourceConfig.official.url)]
          : lock.sources;
      output.result = [for (final s in shown) s.toJson()];
      if (lock.sources.isEmpty) {
        output.line('The official catalog (none recorded in the project):');
      }
      for (final s in shown) {
        output.line('${s.id}  ${s.url}');
      }
      return 0;
    }
    if (rest.length != 2 || (rest.first != 'add' && rest.first != 'remove')) {
      throw const UsageFailure(
        'Use: sources, sources add <url>, or '
        'sources remove <id|url>.',
      );
    }
    final target = rest[1];
    // What to add is read first (from the web, maybe); the lockfile is read
    // and written holding the project's lock, so no other change is lost.
    LockedSource? adding;
    var items = 0;
    if (rest.first == 'add') {
      final config = SourceConfig(here(target, url: true));
      final (source, fetched) = await storeFailures(() async {
        final source = storeFor(project).sourceFor(config);
        return (source, await source.fetchIndex(refresh: true));
      });
      adding = LockedSource(
        fetched.index.source.id,
        project.recordedSource(source.indexUri),
      );
      items = fetched.index.items.length;
    }
    final next = await storeFailures(
      () async => StoreInstaller.withLockSync(project, () {
        final lock = project.readLock();
        final StoreLock next;
        if (adding != null) {
          // A project with none recorded reads the official catalog: adding
          // a source adds to it, never replaces it.
          final current = lock.sources.isNotEmpty
              ? lock.sources
              : [
                  LockedSource(
                    SourceConfig.officialId,
                    SourceConfig.official.url,
                  ),
                ];
          final clash = current.where(
            (s) => s.id == adding!.id && s.url != adding.url,
          );
          if (clash.isNotEmpty) {
            throw CommandFailure(
              'The catalog at ${adding.url} calls itself "${adding.id}", as '
              '${clash.first.url} does. Remove that one first if this one '
              'replaces it.',
            );
          }
          next = StoreLock(
            sources: current,
            items: lock.items,
          ).withSource(adding);
        } else {
          final keep = [
            for (final s in lock.sources)
              if (s.id != target && s.url != target) s,
          ];
          if (keep.length == lock.sources.length) {
            throw CommandFailure('No source "$target" in this project.');
          }
          next = StoreLock(sources: keep, items: lock.items);
        }
        project.writeLock(next);
        return next;
      }),
    );
    output.line(
      adding != null
          ? 'Added ${adding.id} ($items items).'
          : 'Removed $target.',
    );
    output.result = [for (final s in next.sources) s.toJson()];
    return 0;
  }
}

/// `just store cache [clean]`.
@internal
final class CacheCommand extends StoreProjectCommand {
  /// Shows or clears the per-user download cache (--cache names another).
  CacheCommand() : super(catalogs: false, cache: true);

  @override
  String get name => 'cache';

  @override
  String get description =>
      'Show where downloads are kept and how much room they take; '
      '`cache clean` empties it.';

  @override
  String get invocation => '${context.invokedAs} store cache [clean]';

  @override
  Future<int> run() async {
    final dir = cacheDir;
    if (dir == null) {
      throw const CommandFailure('There is no home folder for a cache.');
    }
    final cache = DownloadCache(dir);
    if (rest.isEmpty) {
      final size = cache.sizeInBytes;
      output
        ..result = {'dir': dir, 'bytes': size}
        ..line('$dir  ${_size(size)}');
      return 0;
    }
    if (rest.length != 1 || rest.single != 'clean') {
      throw const UsageFailure('Use: cache, or cache clean.');
    }
    final size = cache.sizeInBytes;
    if (size > 0 && !confirm('Delete ${_size(size)} of downloads in $dir?')) {
      return 1;
    }
    cache.clear();
    output
      ..result = {'dir': dir, 'freed': size}
      ..line('Freed ${_size(size)}.');
    return 0;
  }

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
