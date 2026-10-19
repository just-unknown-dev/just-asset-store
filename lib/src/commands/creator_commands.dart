/// The creators' commands: packing an item, checking one, and building a
/// catalog. None needs a project.
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';

import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/store_index.dart';
import '../install/package_check.dart';
import '../sources/downloader.dart';
import '../sources/store_source.dart';
import '../tools/catalog_builder.dart';
import '../tools/packer.dart';
import 'store_command.dart';

/// `just store pack <folder>`.
final class PackCommand extends JustCommand {
  /// Packs an item into its archive and its catalog version file.
  PackCommand() {
    argParser
      ..addOption(
        'out',
        abbr: 'o',
        valueHelp: 'folder',
        defaultsTo: '.',
        help: 'Where the archive and version file go.',
      )
      ..addOption(
        'url',
        valueHelp: 'base',
        help:
            'Where the archive will be published (its folder); the version '
            'file points at <base>/<archive>.',
      )
      ..addOption(
        'tag',
        help:
            'The GitHub release tag the archive goes to (default: '
            'v<version>), named in just_release.json.',
      );
  }

  @override
  String get name => 'pack';

  @override
  String get description =>
      "Pack a package into its archive, and write the catalog's version file "
      'beside it.';

  @override
  String get invocation => '${context.invokedAs} store pack <folder>';

  @override
  Future<int> run() async {
    final folder = Directory(
      absoluteIn(singleArgument('a folder'), context.workingDirectory),
    );
    final result = Packer.pack(folder);
    final outDir = Directory(
      absoluteIn(argResults!.option('out')!, context.workingDirectory),
    )..createSync(recursive: true);
    final zip = File('${outDir.path}/${result.fileName}')
      ..writeAsBytesSync(result.bytes);
    final base = argResults!.option('url');
    final url = base == null
        ? 'https://github.com/OWNER/REPO/releases/download/'
              '${result.manifest.id}-v${result.manifest.version}/${result.fileName}'
        : '${base.endsWith('/') ? base : '$base/'}${result.fileName}';
    final versionFile =
        File(
          '${outDir.path}/${result.manifest.id}-${result.manifest.version}.json',
        )..writeAsStringSync(
          canonicalJson(result.versionJson(url, published: DateTime.now())),
        );
    // The release's own description, under a name every release shares:
    // what `just add https://github.com/<owner>/<repo>` reads.
    final tag = argResults!.option('tag') ?? 'v${result.manifest.version}';
    final releaseFile = File('${outDir.path}/${JustRelease.fileName}')
      ..writeAsStringSync(
        JustRelease(
          tag: tag,
          manifest: result.manifest,
          version: result.versionJson(result.fileName, published: DateTime.now()),
        ).toText(),
      );
    output
      ..line('Packed ${result.manifest.name} ${result.manifest.version}:')
      ..line('  ${zip.path}')
      ..line(
        '  ${result.files} files, ${result.unpackedSize} bytes unpacked, '
        '${result.bytes.length} packed',
      )
      ..line('  sha256 ${result.sha256}')
      ..line('  catalog version file: ${versionFile.path}')
      ..line('  release file ($tag): ${releaseFile.path}');
    if (base == null) {
      output.line('  (Its URL is a placeholder: pass --url, or edit it.)');
    }
    for (final w in result.warnings) {
      output.warn(w);
    }
    output.result = {
      'id': result.manifest.id,
      'version': '${result.manifest.version}',
      'archive': zip.path,
      'versionFile': versionFile.path,
      'releaseFile': releaseFile.path,
      'tag': tag,
      'sha256': result.sha256,
      'size': result.bytes.length,
      'files': result.files,
      'url': url,
    };
    return 0;
  }
}

/// `just store validate <folder|zip>`.
final class ValidateCommand extends JustCommand {
  @override
  String get name => 'validate';

  @override
  String get description => 'Check that a package would install.';

  @override
  String get invocation => '${context.invokedAs} store validate <folder|zip>';

  @override
  Future<int> run() async {
    final path = absoluteIn(
      singleArgument('a folder or a .zip'),
      context.workingDirectory,
    );
    if (Directory(path).existsSync()) {
      final r = Packer.pack(Directory(path));
      for (final w in r.warnings) {
        output.warn(w);
      }
      output
        ..result = {
          'id': r.manifest.id,
          'version': '${r.manifest.version}',
          'warnings': r.warnings,
        }
        ..line('${r.manifest.name} ${r.manifest.version} would install.');
      return 0;
    }
    if (!File(path).existsSync()) {
      throw CommandFailure('There is no folder or file at $path.');
    }
    final ZipArchive zip;
    try {
      zip = ZipArchive.read(File(path).readAsBytesSync());
    } on ZipFormatException catch (e) {
      throw CommandFailure('$path is not an archive the store can read: $e');
    }
    final manifestEntry = zip.files.firstWhere(
      (f) =>
          f.path.split('/').last == ItemManifest.fileName &&
          f.path.split('/').length <= 2,
      orElse: () => throw StoreFormatException(
        'No ${ItemManifest.fileName} in the archive.',
        file: path,
      ),
    );
    final manifest = ItemManifest.parse(
      utf8.decode(zip.contentOf(manifestEntry)),
    );
    final item = StoreItem(
      id: manifest.id,
      name: manifest.name,
      kind: manifest.kind,
      category: manifest.category,
      versions: [StoreItemVersion(version: manifest.version)],
    );
    final CheckedPackage checked;
    try {
      checked = PackageCheck.check(zip, item, item.versions.single);
    } on PackageCheckException catch (e) {
      throw CommandFailure('$e');
    }
    for (final n in checked.notes) {
      output.info('note: $n');
    }
    output
      ..result = {
        'id': manifest.id,
        'version': '${manifest.version}',
        'notes': checked.notes,
      }
      ..line('${manifest.name} ${manifest.version} would install.');
    return 0;
  }
}

/// `just store index <build|check|codeowners> <repo>`.
final class IndexCommand extends JustCommand {
  /// Builds or checks a catalog from its repository.
  IndexCommand() {
    argParser
      ..addOption(
        'out',
        abbr: 'o',
        valueHelp: 'folder',
        defaultsTo: 'site',
        help: 'Where `build` writes index.json and the pictures.',
      )
      ..addFlag(
        'download',
        negatable: false,
        help: '`check` also fetches each archive and checks it.',
      )
      ..addOption(
        'only',
        valueHelp: 'id',
        help: 'With --download: only this item.',
      );
  }

  @override
  String get name => 'index';

  @override
  String get description =>
      "Build a catalog's index.json from its repository, check it, or print "
      'its CODEOWNERS.';

  @override
  String get invocation =>
      '${context.invokedAs} store index <build|check|codeowners> <repo>';

  @override
  Future<int> run() async {
    if (rest.length != 2) {
      throw const UsageFailure('index takes what to do and the repository.');
    }
    final repo = Directory(absoluteIn(rest[1], context.workingDirectory));
    try {
      switch (rest.first) {
        case 'codeowners':
          final text = CatalogBuilder.codeowners(repo);
          output.result = {'codeowners': text};
          if (!output.json) context.out.write(text);
          return 0;
        case 'build':
          final build = CatalogBuilder.build(repo);
          final out = Directory(
            absoluteIn(argResults!.option('out')!, context.workingDirectory),
          )..createSync(recursive: true);
          File(
            '${out.path}/index.json',
          ).writeAsStringSync(canonicalJson(build.index.toJson()));
          build.assets.forEach((published, file) {
            File('${out.path}/$published')
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(file.readAsBytesSync());
          });
          output
            ..result = {
              'items': build.index.items.length,
              'index': '${out.path}/index.json',
            }
            ..line(
              'Built ${build.index.items.length} items into '
              '${out.path}/index.json.',
            );
          return 0;
        case 'check':
          return await _check(repo);
      }
    } on CatalogBuildException catch (e) {
      throw CommandFailure('The catalog does not build:\n$e');
    }
    throw UsageFailure('Unknown index command "${rest.first}".');
  }

  Future<int> _check(Directory repo) async {
    final build = CatalogBuilder.build(repo);
    output.line('${build.index.items.length} items build.');
    final results = <Map<String, Object?>>[];
    output.result = {'items': build.index.items.length, 'checked': results};
    if (!argResults!.flag('download')) return 0;
    final only = argResults!.option('only');
    final source = FolderStoreSource(repo.path);
    final downloader = Downloader();
    var failed = 0;
    for (final item in build.index.items) {
      if (only != null && item.id != only) continue;
      for (final v in item.versions) {
        if (v.archive == null) continue;
        try {
          final uri = source.resolve(v.archive!.url);
          final bytes = uri.scheme == 'file'
              ? await downloader.archive(source, item, v)
              : await downloader.archive(HttpStoreSource(uri), item, v);
          PackageCheck.check(ZipArchive.read(bytes), item, v);
          output.line('ok   ${item.id} ${v.version}');
          results.add({'id': item.id, 'version': '${v.version}', 'ok': true});
        } on Object catch (x) {
          failed++;
          output.warn('FAIL ${item.id} ${v.version}: $x');
          results.add({
            'id': item.id,
            'version': '${v.version}',
            'ok': false,
            'error': '$x',
          });
        }
      }
    }
    return failed == 0 ? 0 : 1;
  }
}
