/// `just_release.json`: what a package's GitHub release says it holds.
library;

import 'package:just_core_cli/just_core_cli.dart';

import 'claim_code.dart';
import 'item_manifest.dart';

/// What a package's GitHub release says it holds: `just_release.json`, a
/// file with a fixed name in every release (`just store pack` writes it), so
/// the newest is at `releases/latest/download/just_release.json` — a CDN
/// download, not the rate-limited GitHub API.
final class JustRelease {
  /// The release [tag], holding [manifest]'s package as [version] (its
  /// catalog version entry; the archive's `url` relative to the release).
  const JustRelease({
    required this.tag,
    required this.manifest,
    required this.version,
    this.claim,
  });

  /// The claim code ([claimCode]) of the store account that may publish
  /// it, when its maker put one in.
  final String? claim;

  /// The file's name in every release.
  static const String fileName = GitHubRepo.manifestFile;

  /// The newest format this version reads.
  static const int currentSchema = 1;

  /// The release's tag.
  final String tag;

  /// The package's `just_store.json`.
  final ItemManifest manifest;

  /// The version's catalog entry: archive, SHA-256, requirements.
  final Map<String, Object?> version;

  /// [text] as a release file. Throws [JsonFormatException].
  factory JustRelease.parse(String text) {
    final json = JsonFields.parse(text);
    final schema = json.integer('schema', min: 1);
    if (schema > currentSchema) {
      throw json.error(
        'schema',
        'This release needs a newer Asset Store (format $schema).',
      );
    }
    final raw = json.raw('version');
    if (raw is! Map) throw json.error('version', 'Expected an object.');
    final claim = json.optString('claim');
    if (claim != null && !isClaimCode(claim)) {
      throw json.error('claim', 'Not a claim code (jas1-…).');
    }
    return JustRelease(
      tag: json.string('tag'),
      manifest: ItemManifest.fromJson(json.object('manifest')),
      version: raw.cast<String, Object?>(),
      claim: claim,
    );
  }

  /// The file's text.
  String toText() => canonicalJson(
    compactJson({
      'schema': currentSchema,
      'tag': tag,
      'claim': claim,
      'manifest': manifest.toJson(),
      'version': version,
    }),
  );
}
