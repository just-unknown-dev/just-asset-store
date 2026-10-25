/// Checking a downloaded package before it may enter a project.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../archive/zip_reader.dart';
import '../catalog/item_manifest.dart';
import '../catalog/json.dart';
import '../catalog/store_index.dart';
import 'pubspec_facts.dart';

export 'pubspec_facts.dart';

/// A package the store refuses to install, with every reason found.
final class PackageCheckException implements Exception {
  /// [problems] with [item]'s package.
  const PackageCheckException(this.item, this.problems);

  /// The item's display name.
  final String item;

  /// Each problem, in a sentence.
  final List<String> problems;

  @override
  String toString() =>
      '$item cannot be installed:\n${problems.map((p) => '- $p').join('\n')}';
}

/// What [PackageCheck.checkLayout] reads of a package: every file's path
/// (at the package root: a folder wrapping the package is taken off),
/// which are executable, and the two files the rules read. Where a file's
/// bytes come from is up to the caller: an archive in memory, or an
/// archive on a server read with HTTP ranges ([ZipDirectory]).
final class PackageLayout {
  /// A package of [paths], [executable] among them, whose `pubspec.yaml`
  /// and `just_store.json` are [pubspec] and [manifest] (null: missing).
  const PackageLayout({
    required this.paths,
    this.executable = const {},
    this.pubspec,
    this.manifest,
  });

  /// Every file's path, at the package root.
  final List<String> paths;

  /// The files marked executable.
  final Set<String> executable;

  /// The bytes of `pubspec.yaml`, when it has one.
  final Uint8List? pubspec;

  /// The bytes of `just_store.json`, when it has one.
  final Uint8List? manifest;
}

/// Where the package is among an archive's [PackageCheck.metaEntries]: the
/// folder wrapping it (`''` when none), and its two files the rules read.
typedef PackageMeta = ({String prefix, ZipEntry? pubspec, ZipEntry? manifest});

/// What [PackageCheck.checkLayout] found in a package that follows the
/// rules.
final class PackageFacts {
  /// [manifest], with [notes] for the user and the [dependencies] its
  /// pubspec names.
  const PackageFacts(
    this.manifest, {
    this.notes = const [],
    this.dependencies = const {},
  });

  /// Its `just_store.json`.
  final ItemManifest manifest;

  /// Things worth telling the user that don't stop the install.
  final List<String> notes;

  /// The packages its `pubspec.yaml` depends on (SDKs aside).
  final Set<String> dependencies;
}

/// A package that passed [PackageCheck.check]: its files and manifest.
final class CheckedPackage {
  /// [files] (path → bytes, at the package root) described by [manifest];
  /// those in [executable] were marked executable in the archive.
  const CheckedPackage(
    this.manifest,
    this.files, {
    this.notes = const [],
    this.executable = const {},
    this.dependencies = const {},
  });

  /// The packages its `pubspec.yaml` depends on (SDKs aside): pub resolves
  /// each from pub.dev unless the store installs it.
  final Set<String> dependencies;

  /// Its `just_store.json`.
  final ItemManifest manifest;

  /// Every file, by path inside the package.
  final Map<String, Uint8List> files;

  /// Things worth telling the user that don't stop the install.
  final List<String> notes;

  /// The files the archive marks executable (a Unix mode with `x`): they
  /// are installed executable on macOS and Linux.
  final Set<String> executable;

  /// The total size of its files, in bytes.
  int get size => files.values.fold(0, (sum, f) => sum + f.length);
}

/// The rules a package must follow to be installed.
abstract final class PackageCheck {
  /// Extensions a content item may hold.
  static const Set<String> contentExtensions = {
    'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', // images
    'json', 'yaml', 'yml', 'md', 'txt', 'xml', 'csv', 'svg', // data
    'tmx', 'tsx', 'tmj', 'tsj', 'tx', // Tiled
    'jsprite', 'aseprite', 'ase', 'atlas', 'fnt', // sprites, fonts
    'wav', 'mp3', 'ogg', 'flac', 'm4a', // sound
    'ttf', 'otf', 'ttc', // fonts
    'glsl', 'frag', 'vert', 'yarn', // shaders, dialogue
  };

  /// File names without an extension a package may hold at its root.
  static const Set<String> plainNames = {
    'LICENSE', 'LICENCE', 'README', 'CHANGELOG', 'NOTICE', 'AUTHORS', //
  };

  /// The largest `pubspec.yaml` a package may have, in bytes.
  static const int maxPubspecBytes = 64 * 1024;

  /// The largest `just_store.json` a package may have, in bytes.
  static const int maxManifestBytes = 256 * 1024;

  /// Top-level folders a package may never hold: native code, build hooks
  /// that run on the user's machine, scripts.
  static const Set<String> forbiddenFolders = {
    'hook', 'android', 'ios', 'macos', 'windows', 'linux', 'web', 'bin', //
    'tool', 'build',
  };

  /// The unpacked files of [zip], the archive of [version] of [item], if
  /// it follows the rules; else throws [PackageCheckException] listing
  /// every problem found.
  ///
  /// A single top-level folder holding the package (as GitHub's source
  /// archives have) is unwrapped.
  ///
  /// With [matchDependencies] (unless [version] comes from no catalog: a
  /// restore from the lockfile), the store items its manifest needs must
  /// be exactly those [version] lists: the store installs what the catalog
  /// says, and pub would look on pub.dev for any other.
  static CheckedPackage check(
    ZipArchive zip,
    StoreItem item,
    StoreItemVersion version, {
    bool matchDependencies = true,
  }) {
    final (layout, top) = _layoutOf(zip);
    // Every rule first: a package that breaks one is refused before
    // anything else in it is unpacked.
    final facts = checkLayout(
      layout,
      item,
      version,
      matchDependencies: matchDependencies,
    );
    return CheckedPackage(
      facts.manifest,
      {
        for (final e in zip.files)
          if (e.path.length > top.length) e.path.substring(top.length):
              zip.contentOf(e),
      },
      notes: facts.notes,
      executable: layout.executable,
      dependencies: facts.dependencies,
    );
  }

  /// What [check] finds, without keeping the files: every rule, then every
  /// file unpacked and checked against its size and CRC-32, one at a time —
  /// for a tool that vets archives too large to hold unpacked. Throws
  /// [PackageCheckException] or [ZipFormatException].
  static PackageFacts verify(
    ZipArchive zip,
    StoreItem item,
    StoreItemVersion version, {
    bool matchDependencies = true,
  }) {
    final (layout, _) = _layoutOf(zip);
    final facts = checkLayout(
      layout,
      item,
      version,
      matchDependencies: matchDependencies,
    );
    for (final e in zip.files) {
      zip.contentOf(e);
    }
    return facts;
  }

  /// [zip]'s layout, and the folder it wraps the package in (`''` when
  /// none).
  static (PackageLayout, String) _layoutOf(ZipArchive zip) =>
      (layoutFromEntries(zip.files, zip.contentOf), metaEntries(zip.files).prefix);

  /// The layout of the package among an archive's [files], [content]
  /// giving the bytes of the two files the rules read. A file over its
  /// limit ([maxPubspecBytes], [maxManifestBytes]) is never read: it is
  /// passed on as that many bytes and one more, which the rules refuse.
  static PackageLayout layoutFromEntries(
    Iterable<ZipEntry> files,
    Uint8List Function(ZipEntry entry) content,
  ) {
    final meta = metaEntries(files);
    final top = meta.prefix;
    Uint8List? small(ZipEntry? e, int max) => e == null
        ? null
        : e.size > max
        ? Uint8List(max + 1)
        : content(e);
    return PackageLayout(
      paths: [
        for (final e in files)
          if (e.path.length > top.length) e.path.substring(top.length),
      ],
      executable: {
        for (final e in files)
          if (e.isExecutable && e.path.length > top.length)
            e.path.substring(top.length),
      },
      pubspec: small(meta.pubspec, maxPubspecBytes),
      manifest: small(meta.manifest, maxManifestBytes),
    );
  }

  /// The layout of the package in the archive [dir] describes — an archive
  /// on a server, say — fetching through [read] (bytes `start` up to `end`)
  /// only the two small files the rules read. With [checkLayout], the same
  /// verdict as [check] gives once the archive is downloaded, before it is.
  static Future<PackageLayout> layoutOf(
    ZipDirectory dir,
    Future<Uint8List> Function(int start, int end) read,
  ) async {
    final meta = metaEntries(dir.files);
    final fetched = <ZipEntry, Uint8List>{};
    for (final (entry, max) in [
      (meta.pubspec, maxPubspecBytes),
      (meta.manifest, maxManifestBytes),
    ]) {
      // A file whose packed data is far larger than it may unpack to is
      // not worth fetching: the full check refuses it.
      if (entry == null || entry.size > max) continue;
      if (entry.compressedSize > max + 1024) {
        throw ZipFormatException(
          'Its packed data is far larger than the file.',
          path: entry.path,
        );
      }
      fetched[entry] = await dir.readContent(entry, read);
    }
    return layoutFromEntries(dir.files, (e) => fetched[e]!);
  }

  /// Where the package is among an archive's [files]: a single top-level
  /// folder holding it (as GitHub's source archives have) is its prefix,
  /// and the entries of its `pubspec.yaml` and `just_store.json`.
  static PackageMeta metaEntries(Iterable<ZipEntry> files) {
    final paths = [for (final e in files) e.path];
    final prefix = _prefixOf(paths);
    ZipEntry? at(String path) {
      for (final e in files) {
        if (e.path == path) return e;
      }
      return null;
    }

    return (
      prefix: prefix,
      pubspec: at('${prefix}pubspec.yaml'),
      manifest: at('$prefix${ItemManifest.fileName}'),
    );
  }

  /// The rules of [check], on what [layout] says of a package: every file's
  /// path, and the two files the rules read. Throws [PackageCheckException]
  /// listing every problem found.
  static PackageFacts checkLayout(
    PackageLayout layout,
    StoreItem item,
    StoreItemVersion version, {
    bool matchDependencies = true,
  }) {
    final problems = <String>[];
    final notes = <String>[];
    final files = layout.paths.toSet();
    final pubspecBytes = layout.pubspec;
    final manifestBytes = layout.manifest;
    if (manifestBytes != null && manifestBytes.length > maxManifestBytes) {
      throw PackageCheckException(item.name, [
        'Its ${ItemManifest.fileName} is larger than '
            '${maxManifestBytes ~/ 1024} KiB.',
      ]);
    }
    if (pubspecBytes == null) problems.add('It has no pubspec.yaml.');
    if (manifestBytes == null) {
      problems.add('It has no ${ItemManifest.fileName}.');
    }
    if (problems.isNotEmpty) {
      throw PackageCheckException(item.name, problems);
    }

    ItemManifest manifest;
    try {
      manifest = ItemManifest.parse(utf8.decode(manifestBytes!));
    } on StoreFormatException catch (e) {
      throw PackageCheckException(item.name, [
        'Its ${ItemManifest.fileName} is invalid: ${e.inFile(ItemManifest.fileName)}',
      ]);
    } on FormatException {
      throw PackageCheckException(item.name, [
        'Its ${ItemManifest.fileName} is not UTF-8 text.',
      ]);
    }
    if (manifest.id != item.id) {
      problems.add('Its manifest names "${manifest.id}", not "${item.id}".');
    }
    if (manifest.version != version.version) {
      problems.add(
        'Its manifest says version ${manifest.version}, not ${version.version}.',
      );
    }
    if (manifest.kind != item.kind) {
      problems.add(
        'Its manifest says it is ${manifest.kind.id}, not ${item.kind.id}.',
      );
    }
    if (manifest.category != item.category) {
      problems.add(
        'Its manifest puts it in "${manifest.category}", not '
        '"${item.category}".',
      );
    }
    if (matchDependencies) {
      final listed = version.dependencies;
      final declared = manifest.dependencies;
      final differ = [
        for (final id in {...listed.keys, ...declared.keys})
          if ('${listed[id]}' != '${declared[id]}') id,
      ]..sort();
      if (differ.isNotEmpty) {
        problems.add(
          'Its manifest and the catalog disagree on the store items it needs '
          '(${differ.map((id) => '$id: ${declared[id] ?? 'not in the manifest'} '
              'against ${listed[id] ?? 'not in the catalog'}').join('; ')}).',
        );
      }
    }

    // A pubspec is a page of text: anything far larger is not one, and is
    // not worth the time it would take to read.
    if (pubspecBytes!.length > maxPubspecBytes) {
      throw PackageCheckException(item.name, [
        'Its pubspec.yaml is larger than ${maxPubspecBytes ~/ 1024} KiB.',
      ]);
    }
    final PubspecFacts pubspec;
    try {
      final text = utf8.decode(pubspecBytes);
      if (const LineSplitter().convert(text).any((l) => l.length > 1000)) {
        throw PackageCheckException(item.name, [
          'Its pubspec.yaml has a line longer than 1000 characters.',
        ]);
      }
      pubspec = PubspecFacts.parse(text);
    } on FormatException {
      throw PackageCheckException(item.name, ['Its pubspec.yaml is not text.']);
    } on PubspecFormatException catch (e) {
      throw PackageCheckException(item.name, [
        'Its pubspec.yaml: ${e.message}',
      ]);
    }
    if (pubspec.name != item.id) {
      problems.add('Its pubspec names "${pubspec.name}", not "${item.id}".');
    }
    if (pubspec.version != '${version.version}') {
      problems.add(
        'Its pubspec says version ${pubspec.version}, not ${version.version}.',
      );
    }
    final deps = pubspec.dependencies;
    // What pub may fetch for it: versions from pub.dev, or an SDK. Anything
    // else — a path, git, another package server, or a form this check
    // does not know — would bring in code no catalog pinned.
    for (final e in deps.entries) {
      final spec = e.value;
      if (spec is OtherPubDependency) {
        problems.add(
          'It depends on "${e.key}" by ${spec.what}. Store packages depend '
          'on versions from pub.dev or on an SDK, never by path, git or '
          'another package server; the store points them at installed '
          'copies.',
        );
      }
      if (item.kind == ItemKind.content && spec is! SdkPubDependency) {
        problems.add(
          'A content item depends on nothing, but it needs "${e.key}".',
        );
      }
    }
    // The packages it brings from pub.dev are the ones the catalog shows
    // (store items aside, which the manifest names).
    if (matchDependencies && item.kind != ItemKind.content) {
      final fromPub = {
        for (final name in pubspec.hosted.keys)
          if (!manifest.dependencies.containsKey(name)) name,
      };
      final listed = version.pubDependencies.keys.toSet();
      final differ = [
        ...fromPub.difference(listed),
        ...listed.difference(fromPub),
      ]..sort();
      if (differ.isNotEmpty) {
        problems.add(
          'Its pubspec and the catalog disagree on the packages it needs '
          'from pub.dev (${differ.join(', ')}). A store item it needs '
          'belongs in its ${ItemManifest.fileName} dependencies, or pub '
          'would look for another package of that name on pub.dev.',
        );
      }
    }
    // Every plugin says how finished it is: the store and the editor show
    // it, and hide experimental and deprecated ones until asked.
    if (item.kind.isPlugin && manifest.stage == null) {
      problems.add(
        'Its ${ItemManifest.fileName} names no "stage": "stable", "beta", '
        '"experimental" or "deprecated".',
      );
    }
    if (matchDependencies &&
        (manifest.stage != version.stage ||
            manifest.replacedBy != version.replacedBy)) {
      String says(ItemStage? s, String? by) =>
          '${s?.id ?? 'none'}${by == null ? '' : ', replaced by $by'}';
      problems.add(
        'Its manifest and the catalog disagree on its stage: '
        '${says(manifest.stage, manifest.replacedBy)} against '
        '${says(version.stage, version.replacedBy)}.',
      );
    }
    if (matchDependencies) {
      final listed = version.permissions;
      final declared = manifest.permissions;
      if (listed.length != declared.length || !listed.containsAll(declared)) {
        String names(Set<ItemPermission> s) =>
            s.isEmpty ? 'nothing' : [for (final p in s) p.id].join(', ');
        problems.add(
          'Its manifest and the catalog disagree on what it may do: '
          '${names(declared)} against ${names(listed)}. The store shows '
          'users what the catalog says.',
        );
      }
    }
    final native = [
      ...version.nativePlugins,
      if (pubspec.hasPlugin) item.id,
    ];
    if (native.isNotEmpty &&
        !manifest.permissions.contains(ItemPermission.native)) {
      problems.add(
        'It brings native code (${native.join(', ')}), but its '
        '${ItemManifest.fileName} does not list "native" in its '
        'permissions.',
      );
    }
    if (pubspec.hasPlugin) {
      if (item.kind == ItemKind.content) {
        problems.add('A content item cannot be a Flutter plugin.');
      } else {
        notes.add(
          '${item.name} is a Flutter plugin: its native code builds into the '
          'app.',
        );
      }
    }

    // Every file: a safe kind, in a place allowed for it.
    final allowed = {...contentExtensions, if (item.kind.isCode) 'dart'};
    for (final path in files) {
      final parts = path.split('/');
      final name = parts.last;
      // Windows and macOS find `Hook/` when the toolchain asks for `hook/`:
      // folder and file names are compared as those file systems do.
      final top = parts.first.toLowerCase();
      final lowerName = name.toLowerCase();
      if (parts.any((p) => p.startsWith('.')) &&
          !(parts.length == 1 &&
              const {
                '.gitignore',
                '.pubignore',
                '.gitattributes',
              }.contains(name))) {
        problems.add('"$path" is hidden or inside a hidden folder.');
        continue;
      }
      // The store's own tools ship a command-line tool in bin/; only
      // official code may, never anyone else's.
      final officialTool =
          top == 'bin' && item.kind.isCode && item.trust == TrustLevel.official;
      if (parts.length > 1 && forbiddenFolders.contains(top) && !officialTool) {
        problems.add(
          '"$path" is in ${parts.first}/, which store packages may not have.',
        );
        continue;
      }
      if (lowerName == 'pubspec.lock' ||
          lowerName == 'pubspec_overrides.yaml') {
        problems.add('"$path" must not be in a package.');
        continue;
      }
      if (parts.length == 1 && name.startsWith('.')) continue;
      final dot = name.lastIndexOf('.');
      if (dot < 0) {
        if (parts.length == 1 && plainNames.contains(name.toUpperCase())) {
          continue;
        }
        problems.add('"$path" has no file type.');
        continue;
      }
      final ext = name.substring(dot + 1).toLowerCase();
      if (!allowed.contains(ext)) {
        problems.add(
          item.kind.isCode
              ? '"$path" is a .$ext file, which store packages may not hold.'
              : '"$path" is a .$ext file, which content items may not hold.',
        );
      }
    }

    // The generated registries import these: a missing one would stop the
    // editor or the game from compiling after the install.
    final ownPrefix = 'package:${manifest.id}/';
    for (final library in [
      for (final m in manifest.modules) m.library,
      for (final x in manifest.extensions) x.library,
    ]) {
      final file = 'lib/${library.substring(ownPrefix.length)}';
      if (!files.contains(file)) {
        problems.add('Its manifest registers $library, but it has no $file.');
      }
    }
    if (item.kind == ItemKind.content) {
      _checkContent(manifest, pubspec, files, problems);
    }
    for (final preview in manifest.previews) {
      if (!files.contains(preview)) {
        problems.add('The preview "$preview" is missing.');
      }
    }
    if (problems.isNotEmpty) {
      throw PackageCheckException(item.name, problems);
    }
    return PackageFacts(
      manifest,
      notes: notes,
      dependencies: {
        for (final e in deps.entries)
          if (e.value is! SdkPubDependency) e.key,
      },
    );
  }

  /// Content ships only what its asset folders hold, and Flutter does not
  /// look into subfolders: every file must sit directly in one of them, and
  /// the pubspec must list exactly those folders.
  static void _checkContent(
    ItemManifest manifest,
    PubspecFacts pubspec,
    Set<String> files,
    List<String> problems,
  ) {
    final listed = pubspec.assets.toSet();
    final declared = manifest.assetFolders.toSet();
    for (final f in declared.difference(listed)) {
      problems.add('The asset folder "$f" is not in its pubspec.');
    }
    for (final f in listed.difference(declared)) {
      problems.add('Its pubspec lists "$f", which its manifest does not.');
    }
    final meta = {'pubspec.yaml', ItemManifest.fileName, ...manifest.previews};
    final used = <String>{};
    for (final path in files) {
      if (meta.contains(path) || !path.contains('/')) continue;
      final folder = path.substring(0, path.lastIndexOf('/') + 1);
      if (declared.contains(folder)) {
        used.add(folder);
      } else {
        problems.add(
          '"$path" is not directly in an asset folder, so it would not ship. '
          'Add "$folder" to content.assetFolders and the pubspec.',
        );
      }
    }
    for (final f in declared.difference(used)) {
      problems.add('The asset folder "$f" is empty.');
    }
  }

  /// The folder (`top/`) that wraps the package among [paths], or `''`
  /// when the package is at the archive's root.
  static String _prefixOf(List<String> paths) {
    if (paths.contains('pubspec.yaml') || paths.isEmpty) return '';
    final firsts = paths.map((p) => p.split('/').first).toSet();
    if (firsts.length != 1) return '';
    final top = '${firsts.single}/';
    return paths.contains('${top}pubspec.yaml') ? top : '';
  }
}
