/// An item a catalog lists, with its versions and their archives.
library;

import 'package:just_core_cli/just_core_cli.dart';

import 'item_details.dart';
import 'item_traits.dart';
import 'plain_text.dart';

/// A version's ZIP archive and the facts that pin it.
final class StoreArchive {
  /// The archive at [url], whose SHA-256 is [sha256].
  const StoreArchive({
    required this.url,
    required this.sha256,
    required this.size,
    this.unpackedSize,
    this.files,
  });

  /// The largest archive the store downloads: 512 MiB.
  static const int maxSize = 512 << 20;

  /// Reads one from [json].
  factory StoreArchive.fromJson(JsonFields json) {
    final sha = json.string('sha256');
    if (!isSha256Hex(sha)) {
      throw json.error('sha256', 'Expected 64 lowercase hex digits.');
    }
    final url = json.string('url');
    _checkUrl(json, 'url', url);
    return StoreArchive(
      url: url,
      sha256: sha,
      size: json.integer('size', min: 1),
      unpackedSize: json.optInt('unpackedSize'),
      files: json.optInt('files'),
    );
  }

  /// Where to download it: an `https:` URL, or a path relative to the
  /// catalog's `index.json`.
  final String url;

  /// Its SHA-256 as 64 lowercase hex digits. Downloads that don't match are
  /// refused.
  final String sha256;

  /// Its size in bytes.
  final int size;

  /// The total size of its files once unpacked, in bytes.
  final int? unpackedSize;

  /// How many files it holds.
  final int? files;

  /// This archive as JSON.
  Map<String, Object?> toJson() => compactJson({
    'url': url,
    'sha256': sha256,
    'size': size,
    'unpackedSize': unpackedSize,
    'files': files,
  });
}

/// One version of an item.
final class StoreItemVersion {
  /// A version; see the fields for what each part means.
  const StoreItemVersion({
    required this.version,
    this.published,
    this.yanked = false,
    this.blocked = false,
    this.notes,
    this.archive,
    this.broker,
    this.access = AccessLevel.public,
    this.pubConstraint,
    this.requires = const {},
    this.dependencies = const {},
    this.pubDependencies = const {},
    this.nativePlugins = const [],
    this.permissions = const {},
    this.stage,
    this.replacedBy,
  });

  /// Reads one from [json], for an item of [kind].
  factory StoreItemVersion.fromJson(JsonFields json, ItemKind kind) {
    final access = json.choice(
      'access',
      AccessLevel.byId,
      fallback: AccessLevel.public,
    );
    final archive = json.optObject('archive');
    final download = json.optObject('download');
    final broker = download?.string('broker');
    if (broker != null) _checkUrl(download!, 'broker', broker);
    final constraintText = json.optString('constraint');
    final v = StoreItemVersion(
      version: json.version('version'),
      published: json.optTime('published'),
      yanked: json.flag('yanked'),
      blocked: json.flag('blocked'),
      notes: optPlainText(json, 'notes', json.optString('notes'), lines: true),
      archive: archive == null ? null : StoreArchive.fromJson(archive),
      broker: broker,
      access: access,
      pubConstraint: constraintText == null
          ? null
          : VersionConstraint.tryParse(constraintText) ??
                (throw json.error('constraint', 'Not a version constraint.')),
      requires: _packages(json, 'requires', json.constraints('requires')),
      dependencies: json.constraints('dependencies'),
      pubDependencies: _packages(
        json,
        'pubDependencies',
        json.constraints('pubDependencies'),
      ),
      nativePlugins: [
        for (final p in json.strings('nativePlugins'))
          _packageName(json, 'nativePlugins', p),
      ],
      permissions: _permissions(json),
      stage: ItemStage.optFrom(json, 'stage'),
      replacedBy: switch (json.optString('replacedBy')) {
        final id? => _packageName(json, 'replacedBy', id),
        null => null,
      },
    );
    if (kind == ItemKind.content && v.permissions.isNotEmpty) {
      throw json.error('permissions', 'A content item holds no code.');
    }
    if (kind.isVendored) {
      if (access == AccessLevel.public && v.archive == null) {
        throw json.error('archive', 'A public version needs an archive.');
      }
      if (access == AccessLevel.entitled && v.broker == null) {
        throw json.error(
          'download',
          'A version for entitled users needs a download broker.',
        );
      }
    }
    for (final dep in v.dependencies.keys) {
      if (!PackageNames.isId(dep)) {
        throw json.error('dependencies', '"$dep" is not an item id.');
      }
    }
    return v;
  }

  /// The version number.
  final Version version;

  /// When it was published.
  final DateTime? published;

  /// Withdrawn by its publisher: hidden from new installs, kept where
  /// already installed.
  final bool yanked;

  /// Taken down (a licence problem, say): hidden, and projects that have it
  /// are warned.
  final bool blocked;

  /// What changed, for the details pane.
  final String? notes;

  /// The archive, for vendored items anyone may download.
  final StoreArchive? archive;

  /// The download service to ask for the archive, for [AccessLevel.entitled]
  /// versions. Reserved for paid items.
  final String? broker;

  /// Who may download it.
  final AccessLevel access;

  /// For runtime libraries: the constraint written into the pubspec
  /// (`^1.2.0`).
  final VersionConstraint? pubConstraint;

  /// The SDKs and core packages it needs: `sdk`, `flutter`,
  /// `just_game_engine`, `just_game_engine_editor`.
  final Map<String, VersionConstraint> requires;

  /// Other store items it needs, by id.
  final Map<String, VersionConstraint> dependencies;

  /// Packages from pub.dev it depends on.
  final Map<String, VersionConstraint> pubDependencies;

  /// Flutter plugins with native code it brings in. They are compiled into
  /// every build of the game, even when only the editor uses them.
  final List<String> nativePlugins;

  /// What its code does that a user should know before installing it, as
  /// its manifest declares: shown before every install.
  final Set<ItemPermission> permissions;

  /// How finished it is, as its manifest says; every plugin names one.
  final ItemStage? stage;

  /// For a [ItemStage.deprecated] version: the item that replaces it.
  final String? replacedBy;

  /// Whether new installs may pick it.
  bool get isAvailable => !yanked && !blocked;

  /// This version as JSON.
  Map<String, Object?> toJson() => compactJson({
    'version': '$version',
    'published': published?.toIso8601String(),
    'yanked': yanked ? true : null,
    'blocked': blocked ? true : null,
    'notes': notes,
    'archive': archive?.toJson(),
    'download': broker == null ? null : {'broker': broker},
    'access': access == AccessLevel.public ? null : access.name,
    'constraint': pubConstraint?.toString(),
    'requires': {for (final e in requires.entries) e.key: '${e.value}'},
    'dependencies': {for (final e in dependencies.entries) e.key: '${e.value}'},
    'pubDependencies': {
      for (final e in pubDependencies.entries) e.key: '${e.value}',
    },
    'nativePlugins': nativePlugins,
    'permissions': [
      for (final p in ItemPermission.values)
        if (permissions.contains(p)) p.id,
    ],
    'stage': stage?.id,
    'replacedBy': replacedBy,
  });
}

/// Something a catalog offers: its description and every version.
final class StoreItem {
  /// An item; see the fields for what each part means.
  const StoreItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.category,
    required this.versions,
    this.summary = '',
    this.description,
    this.tags = const [],
    this.author,
    this.license,
    this.thumbnail,
    this.previews = const [],
    this.publisher = 'just',
    this.trust = TrustLevel.community,
    this.sourceRepo,
    this.discussionUrl,
    this.stats,
    this.pricing = StorePricing.free,
    this.pubPackage,
    this.repoId,
    this.unavailable = false,
  });

  /// Reads one from [json].
  factory StoreItem.fromJson(JsonFields json) {
    final id = json.string('id');
    final idProblem = PackageNames.idProblem(id);
    if (idProblem != null) throw json.error('id', idProblem);
    final kind = json.choice('kind', ItemKind.byId);
    final category = json.string('category');
    if (!PackageNames.isCategory(category)) {
      throw json.error('category', '"$category" is not a category id.');
    }
    final pub = json.optObject('pub');
    if (kind == ItemKind.runtimeLibrary && pub == null) {
      throw json.error('pub', 'A runtime library names its pub.dev package.');
    }
    // The store adds it to the pubspec under its id: the package pub
    // fetches must be the one the catalog names.
    if (pub != null && pub.string('package') != id) {
      throw pub.error(
        'package',
        'An item\'s id is its package\'s name, so this must be "$id".',
      );
    }
    final versions = [
      for (final v in json.objects('versions'))
        StoreItemVersion.fromJson(v, kind),
    ];
    if (versions.isEmpty) throw json.error('versions', 'No versions.');
    final seen = <Version>{};
    for (final v in versions) {
      if (!seen.add(v.version)) {
        throw json.error('versions', 'Version ${v.version} is listed twice.');
      }
    }
    final author = json.optObject('author');
    final license = json.optObject('license');
    final stats = json.optObject('stats');
    final pricing = json.optObject('pricing');
    return StoreItem(
      id: id,
      name: plainText(json, 'name', json.string('name')),
      kind: kind,
      category: category,
      versions: versions,
      summary: optPlainText(json, 'summary', json.optString('summary')) ?? '',
      description: optPlainText(
        json,
        'description',
        json.optString('description'),
        lines: true,
      ),
      tags: [for (final t in json.strings('tags')) plainText(json, 'tags', t)],
      author: author == null ? null : StoreAuthor.fromJson(author),
      license: license == null ? null : StoreLicense.fromJson(license),
      thumbnail: _optUrl(json, 'thumbnail'),
      previews: [
        for (final p in json.strings('previews')) _url(json, 'previews', p),
      ],
      publisher:
          optPlainText(json, 'publisher', json.optString('publisher')) ??
          'just',
      trust: json.choice(
        'trust',
        TrustLevel.byId,
        fallback: TrustLevel.community,
      ),
      sourceRepo: optPlainText(
        json,
        'sourceRepo',
        json.optString('sourceRepo'),
      ),
      discussionUrl: optPlainText(
        json,
        'discussionUrl',
        json.optString('discussionUrl'),
      ),
      stats: stats == null ? null : StoreStats.fromJson(stats),
      pricing: pricing == null
          ? StorePricing.free
          : StorePricing.fromJson(pricing),
      pubPackage: pub?.string('package'),
      repoId: json.optInt('repoId', min: 1),
      unavailable: json.flag('unavailable'),
    );
  }

  /// Its id: also its Dart package name, so unique across the catalog and
  /// pub.dev.
  final String id;

  /// Its display name.
  final String name;

  /// What it is, which decides how it installs.
  final ItemKind kind;

  /// The store category it is shown under, and the folder it installs
  /// into: `packages/{category}/{id}/` for content,
  /// `plugins/{category}/{id}/` for an editor extension or a kit.
  final String category;

  /// One line for its card.
  final String summary;

  /// A longer description, plain text.
  final String? description;

  /// Search words.
  final List<String> tags;

  /// Who made it.
  final StoreAuthor? author;

  /// Its licence.
  final StoreLicense? license;

  /// Its card image, relative to `index.json` or a full URL.
  final String? thumbnail;

  /// Larger images for its details pane.
  final List<String> previews;

  /// The publisher id (a file in the catalog's `publishers/`).
  final String publisher;

  /// How far the store vouches for it.
  final TrustLevel trust;

  /// Its source repository.
  final String? sourceRepo;

  /// A discussion where users talk about it.
  final String? discussionUrl;

  /// Downloads and likes, when the catalog counts them.
  final StoreStats? stats;

  /// What it costs.
  final StorePricing pricing;

  /// For runtime libraries: the package's name on pub.dev.
  final String? pubPackage;

  /// The numeric id of its GitHub repository, as the store checked it: a
  /// repository deleted and made again under the same name has another
  /// one, so the store can tell a takeover from the original.
  final int? repoId;

  /// Whether the store stopped offering it: its repository was removed or
  /// changed hands. Installed copies keep working; nothing new installs.
  final bool unavailable;

  /// Every version, as listed.
  final List<StoreItemVersion> versions;

  /// Whether it is made by the store's own team.
  bool get isOfficial => trust == TrustLevel.official;

  /// How finished it is: its [latest] version's stage.
  ItemStage? get stage => latest?.stage;

  /// What replaces it, when its [latest] version is deprecated.
  String? get replacedBy =>
      stage == ItemStage.deprecated ? latest?.replacedBy : null;

  /// This item, vouched for at [trust] instead.
  StoreItem withTrust(TrustLevel trust) => StoreItem(
    id: id,
    name: name,
    kind: kind,
    category: category,
    versions: versions,
    summary: summary,
    description: description,
    tags: tags,
    author: author,
    license: license,
    thumbnail: thumbnail,
    previews: previews,
    publisher: publisher,
    trust: trust,
    sourceRepo: sourceRepo,
    discussionUrl: discussionUrl,
    stats: stats,
    pricing: pricing,
    pubPackage: pubPackage,
    repoId: repoId,
    unavailable: unavailable,
  );

  /// The versions new installs may pick.
  Iterable<StoreItemVersion> get available =>
      versions.where((v) => v.isAvailable);

  /// The newest available release, or the newest pre-release when there
  /// is no release; null when nothing is available.
  StoreItemVersion? get latest {
    StoreItemVersion? best;
    StoreItemVersion? bestPre;
    for (final v in available) {
      if (v.version.isPreRelease) {
        if (bestPre == null || v.version > bestPre.version) bestPre = v;
      } else if (best == null || v.version > best.version) {
        best = v;
      }
    }
    return best ?? bestPre;
  }

  /// The listed version [version], or null.
  StoreItemVersion? versionOf(Version version) {
    for (final v in versions) {
      if (v.version == version) return v;
    }
    return null;
  }

  /// The best available version [constraint] allows, or null.
  StoreItemVersion? bestFor(VersionConstraint constraint) {
    final pick = constraint.bestOf(available.map((v) => v.version));
    return pick == null ? null : versionOf(pick);
  }

  /// Whether [query] matches its id, name, summary, tags or author.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return id.contains(q) ||
        name.toLowerCase().contains(q) ||
        summary.toLowerCase().contains(q) ||
        tags.any((t) => t.toLowerCase().contains(q)) ||
        (author?.name.toLowerCase().contains(q) ?? false);
  }

  /// This item as JSON.
  Map<String, Object?> toJson() => compactJson({
    'id': id,
    'name': name,
    'kind': kind.id,
    'category': category,
    'summary': summary.isEmpty ? null : summary,
    'description': description,
    'tags': tags,
    'author': author?.toJson(),
    'license': license?.toJson(),
    'thumbnail': thumbnail,
    'previews': previews,
    'publisher': publisher == 'just' ? null : publisher,
    'trust': trust == TrustLevel.community ? null : trust.name,
    'sourceRepo': sourceRepo,
    'discussionUrl': discussionUrl,
    'stats': stats?.toJson(),
    'pricing': pricing.isFree ? null : pricing.toJson(),
    'pub': pubPackage == null ? null : {'package': pubPackage},
    'repoId': repoId,
    'unavailable': unavailable ? true : null,
    'versions': [for (final v in versions) v.toJson()],
  });
}

final RegExp _packageNamePattern = RegExp(r'^[a-z_][a-z0-9_]{0,63}$');

/// The `permissions` at [json], each one the store knows.
Set<ItemPermission> _permissions(JsonFields json) => {
  for (final name in json.strings('permissions'))
    ItemPermission.byId[name] ??
        (throw json.error(
          'permissions',
          'Expected one of: ${ItemPermission.byId.keys.join(', ')}.',
        )),
};

/// [name] at [key], once it is a package name: what pub would fetch, and
/// what the store prints.
String _packageName(JsonFields json, String key, String name) {
  if (!_packageNamePattern.hasMatch(name)) {
    throw json.error(key, '"$name" is not a package name.');
  }
  return name;
}

/// [map], whose keys at [key] must be package names.
Map<String, VersionConstraint> _packages(
  JsonFields json,
  String key,
  Map<String, VersionConstraint> map,
) {
  for (final name in map.keys) {
    _packageName(json, key, name);
  }
  return map;
}

/// [url], the picture at [key], once [_checkUrl] allows it.
String _url(JsonFields json, String key, String url) {
  _checkUrl(json, key, url, picture: true);
  return url;
}

/// The optional picture at [key], once [_checkUrl] allows it.
String? _optUrl(JsonFields json, String key) {
  final url = json.optString(key);
  return url == null ? null : _url(json, key, url);
}

/// Refuses [url] at [key] unless it is an `https:` address — `http:` too
/// for an archive, which only a catalog on this machine may use — or a path
/// beside `index.json`. A [picture] is fetched as soon as a card shows it,
/// so it gets `https:` only.
void _checkUrl(
  JsonFields json,
  String key,
  String url, {
  bool picture = false,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) throw json.error(key, '"$url" is not a URL.');
  if (uri.hasScheme) {
    if (uri.scheme == 'https' || (!picture && uri.scheme == 'http')) return;
    throw json.error(
      key,
      picture
          ? 'Pictures must be https URLs, or files beside index.json.'
          : 'Only http and https URLs are allowed.',
    );
  }
  // A path relative to index.json: no climbing out, no absolute paths —
  // however its dots and slashes are written (`%2e%2e/`, `..%2f`).
  final String path;
  try {
    path = Uri.decodeFull(url);
  } on Object {
    throw json.error(key, '"$url" is not a URL.');
  }
  if (path.startsWith('/') ||
      path.contains(r'\') ||
      path.split('/').contains('..')) {
    throw json.error(key, '"$url" must stay beside index.json.');
  }
}
