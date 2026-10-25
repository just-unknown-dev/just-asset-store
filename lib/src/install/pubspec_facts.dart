/// What a package's `pubspec.yaml` says, read as pub reads it.
library;

import 'package:yaml/yaml.dart';

import '../catalog/names.dart';
import '../catalog/semver.dart';

/// A pubspec the store can't read, or refuses: not YAML, a duplicate key,
/// a field pub doesn't document, a dependency written in an unknown way.
final class PubspecFormatException implements Exception {
  /// [message] about the pubspec.
  const PubspecFormatException(this.message);

  /// What is wrong, in a sentence.
  final String message;

  @override
  String toString() => message;
}

/// One dependency, as a package's pubspec writes it.
sealed class PubDependency {
  const PubDependency();
}

/// A version from pub.dev: `^1.2.0`, `{version: ^1.2.0}`, or the same with
/// `hosted: https://pub.dev`. [constraint] is null for any version.
final class HostedPubDependency extends PubDependency {
  /// Any version [constraint] allows.
  const HostedPubDependency(this.constraint);

  /// The versions it allows; null for any.
  final VersionConstraint? constraint;
}

/// An SDK's package: `flutter: {sdk: flutter}`.
final class SdkPubDependency extends PubDependency {
  /// The package of SDK [sdk].
  const SdkPubDependency(this.sdk);

  /// The SDK: `flutter`.
  final String sdk;
}

/// Anything else — a path, git, another package server, or a way of
/// writing it the store doesn't read — which [what] names. Code pub would
/// fetch from somewhere no catalog pinned.
final class OtherPubDependency extends PubDependency {
  /// A dependency the store refuses, written as [what].
  const OtherPubDependency(this.what);

  /// How it is written: `path`, `git`, another server.
  final String what;
}

/// What a package's `pubspec.yaml` says, read with `package:yaml` — the
/// reader pub itself uses — so a key spelled with YAML escapes, quotes or
/// the explicit `? key` form reads as pub reads it, and a key written twice
/// is refused.
final class PubspecFacts {
  PubspecFacts._(
    this.name,
    this.version,
    this.assets,
    this.hasPlugin,
    this.dependencies,
  );

  /// The top-level fields pub documents. Any other field is refused: a
  /// store package needs no more, and a new pub feature isn't let through
  /// unread.
  static const Set<String> fields = {
    'name',
    'version',
    'description',
    'homepage',
    'repository',
    'issue_tracker',
    'documentation',
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
    'environment',
    'executables',
    'platforms',
    'publish_to',
    'funding',
    'false_secrets',
    'screenshots',
    'topics',
    'ignored_advisories',
    'flutter',
    // Only `user_defines`, which pub reads from the project's own pubspec
    // alone: a package uses them for its own tests, and installed they do
    // nothing.
    'hooks',
  };

  /// Reads [text]. Throws [PubspecFormatException].
  factory PubspecFacts.parse(String text) {
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw PubspecFormatException('It is not valid YAML: ${e.message}');
    }
    if (doc is! Map) throw const PubspecFormatException('It is not a map.');
    for (final key in doc.keys) {
      if (key is! String || !fields.contains(key)) {
        throw PubspecFormatException(
          'It has a field the store does not read: "$key".',
        );
      }
    }

    final hooks = doc['hooks'];
    if (hooks != null &&
        (hooks is! Map || hooks.keys.any((k) => k != 'user_defines'))) {
      throw const PubspecFormatException(
        'Its hooks: may hold only user_defines:.',
      );
    }

    String? scalar(Object? v) => v == null || v is Map || v is List ? null : '$v';

    final deps = <String, PubDependency>{};
    final rawDeps = doc['dependencies'];
    if (rawDeps != null && rawDeps is! Map) {
      throw const PubspecFormatException('Its dependencies are not a map.');
    }
    for (final e in (rawDeps as Map? ?? const {}).entries) {
      final name = e.key;
      if (name is! String || StoreNames.idProblem(name) != null) {
        throw PubspecFormatException('"${e.key}" is not a package name.');
      }
      deps[name] = _dependency(e.value);
    }

    final assets = <String>[];
    var hasPlugin = false;
    final flutter = doc['flutter'];
    if (flutter is Map) {
      hasPlugin = flutter.containsKey('plugin');
      final list = flutter['assets'];
      if (list != null && list is! List) {
        throw const PubspecFormatException('Its flutter: assets: is not a list.');
      }
      for (final a in (list as List? ?? const [])) {
        // `- folder/`, or `- path: folder/` (with flavors and the rest).
        final path = a is Map ? a['path'] : a;
        if (path is! String) {
          throw const PubspecFormatException(
            'An entry of its flutter: assets: is not a path.',
          );
        }
        assets.add(path);
      }
    } else if (flutter != null) {
      throw const PubspecFormatException('Its flutter: is not a map.');
    }

    return PubspecFacts._(
      scalar(doc['name']),
      scalar(doc['version']),
      assets,
      hasPlugin,
      deps,
    );
  }

  static PubDependency _dependency(Object? spec) {
    if (spec == null) return const HostedPubDependency(null);
    if (spec is String) {
      final c = VersionConstraint.tryParse(spec);
      return c == null ? const OtherPubDependency('an unknown version') : HostedPubDependency(c);
    }
    if (spec is! Map) return const OtherPubDependency('an unknown form');
    final keys = {for (final k in spec.keys) '$k'};
    if (keys.length == 1 && keys.contains('sdk') && spec['sdk'] is String) {
      return SdkPubDependency(spec['sdk'] as String);
    }
    if (keys.isNotEmpty && keys.every({'version', 'hosted'}.contains)) {
      final version = spec['version'];
      final c = version == null
          ? null
          : version is String
          ? VersionConstraint.tryParse(version)
          : null;
      if (version != null && c == null) {
        return const OtherPubDependency('an unknown version');
      }
      final hosted = spec['hosted'];
      final url = hosted is Map ? hosted['url'] : hosted;
      if (hosted != null && (url is! String || !_isPubDev(url))) {
        return const OtherPubDependency('another package server');
      }
      return HostedPubDependency(c);
    }
    return OtherPubDependency(
      keys.contains('git')
          ? 'git'
          : keys.contains('path')
          ? 'path'
          : keys.join(', '),
    );
  }

  /// Whether [url], a dependency's `hosted:` server, is pub.dev.
  static bool _isPubDev(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        (uri.host == 'pub.dev' || uri.host == 'pub.dartlang.org') &&
        !uri.hasPort &&
        uri.pathSegments.every((s) => s.isEmpty);
  }

  /// The package's name.
  final String? name;

  /// Its version, as written.
  final String? version;

  /// Its `flutter: assets:` entries.
  final List<String> assets;

  /// Whether it declares a Flutter plugin.
  final bool hasPlugin;

  /// Its `dependencies`, by package name.
  final Map<String, PubDependency> dependencies;

  /// The dependencies pub fetches from pub.dev, with their constraints.
  Map<String, VersionConstraint?> get hosted => {
    for (final e in dependencies.entries)
      if (e.value case HostedPubDependency(:final constraint))
        e.key: constraint,
  };
}
