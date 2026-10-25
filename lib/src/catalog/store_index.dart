/// A catalog's `index.json`: what a store source offers.
library;

import '../crypto/sha256.dart';
import 'json.dart';
import 'names.dart';
import 'plain_text.dart';
import 'semver.dart';

/// What an item is, which decides how it installs.
enum ItemKind {
  /// Art, sound, tilesets… An asset-only package.
  content('content'),

  /// Tools that only run in the editor, like the Sprite Studio.
  editorExtension('editor-extension'),

  /// Game code with an editor part, like the platformer kit.
  kit('kit'),

  /// Game code from pub.dev, added as a hosted dependency.
  runtimeLibrary('runtime-library'),

  /// A whole project to start from (`just create --template`): laid over
  /// a new project, never installed into one.
  template('template');

  const ItemKind(this.id);

  /// The name used in JSON.
  final String id;

  /// Whether items of this kind hold Dart code.
  bool get isCode => this != content;

  /// Whether items of this kind are plugins: code that comes only through
  /// the store, published on GitHub and never on pub.dev — editor
  /// extensions and kits.
  bool get isPlugin => this == editorExtension || this == kit;

  /// Whether its source is copied into the project (everything but pub.dev
  /// libraries and templates), into [installFolder].
  bool get isVendored => this != runtimeLibrary && this != template;

  /// The project folder an item of this kind is copied into, as
  /// `{installFolder}/{category}/{name}/`: `plugins` for a plugin,
  /// `packages` for content. Null when it isn't copied in ([isVendored]).
  String? get installFolder => switch (this) {
    content => 'packages',
    editorExtension || kit => 'plugins',
    runtimeLibrary || template => null,
  };

  /// Whether installing one means restarting the editor: code can't be
  /// loaded into a running app.
  bool get needsRestart => isCode && this != template;

  /// The kinds, keyed by their JSON names.
  static final Map<String, ItemKind> byId = {for (final k in values) k.id: k};
}

/// How far the store vouches for an item's publisher.
enum TrustLevel {
  /// Made by the store's own team.
  official,

  /// A known publisher whose earlier versions were reviewed.
  verified,

  /// Anyone else.
  community;

  /// The levels, keyed by their JSON names.
  static final Map<String, TrustLevel> byId = {
    for (final t in values) t.name: t,
  };
}

/// Something an item's code does that a user should know before installing
/// it. Dart code in the editor can't be fenced in, so these are declared,
/// shown before installing, and never hidden; native code that isn't
/// declared is refused.
enum ItemPermission {
  /// It connects to the internet.
  network('network', 'Connects to the internet'),

  /// It reads or writes files outside the project.
  files('files', 'Reads or writes files outside the project'),

  /// It starts other programs.
  processes('processes', 'Runs other programs'),

  /// It brings native code: Flutter plugins.
  native('native', 'Brings native code (Flutter plugins)');

  const ItemPermission(this.id, this.label);

  /// The name used in JSON.
  final String id;

  /// What it means, for the install preview.
  final String label;

  /// The permissions, keyed by their JSON names.
  static final Map<String, ItemPermission> byId = {
    for (final p in values) p.id: p,
  };

  /// [permissions] as one phrase, in their usual order: "connects to the
  /// internet and runs other programs".
  static String describe(Iterable<ItemPermission> permissions) {
    final parts = [
      for (final p in values)
        if (permissions.contains(p))
          p.label[0].toLowerCase() + p.label.substring(1),
    ];
    if (parts.length < 2) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} and '
        '${parts.last}';
  }
}

/// How finished a version of an item is, as its own `just_store.json`
/// says. Every plugin (editor tool or kit) names one.
enum ItemStage {
  /// Ready for real projects.
  stable('stable', 'Stable'),

  /// Complete enough to use; may still change.
  beta('beta', 'Beta'),

  /// A first try: it may change or break between versions. Listed only to
  /// those who ask, and installing it asks first.
  experimental('experimental', 'Experimental'),

  /// No longer developed: listed only to a search, installing it asks
  /// first, and projects that have it are told what replaces it.
  deprecated('deprecated', 'Deprecated');

  const ItemStage(this.id, this.label);

  /// The name used in JSON.
  final String id;

  /// What it is called on a badge.
  final String label;

  /// Whether a store lists it only when asked: experimental and deprecated
  /// items.
  bool get hiddenByDefault => this == experimental || this == deprecated;

  /// The stages, keyed by their JSON names.
  static final Map<String, ItemStage> byId = {for (final s in values) s.id: s};

  /// The stage named at [key] in [json], or null when there is none.
  static ItemStage? optFrom(JsonFields json, String key) {
    final id = json.optString(key);
    if (id == null) return null;
    return byId[id] ??
        (throw json.error(key, 'Expected one of: ${byId.keys.join(', ')}.'));
  }
}

/// Who can download a version.
enum AccessLevel {
  /// Anyone: the archive's URL is in the catalog.
  public,

  /// Only users entitled to it (a paid item): a download service hands out
  /// the archive after checking.
  entitled;

  /// The levels, keyed by their JSON names.
  static final Map<String, AccessLevel> byId = {
    for (final a in values) a.name: a,
  };
}

/// Whether an item costs money.
enum PricingModel {
  /// Free to use under its licence.
  free,

  /// Bought once; see [StorePricing].
  paid;

  /// The models, keyed by their JSON names.
  static final Map<String, PricingModel> byId = {
    for (final p in values) p.name: p,
  };
}

/// The licence an item is offered under.
final class StoreLicense {
  /// A licence identified by its SPDX id (`CC0-1.0`, `CC-BY-4.0`, `MIT`).
  const StoreLicense(this.spdx, {this.attribution, this.file});

  /// Reads one from [json].
  factory StoreLicense.fromJson(JsonFields json) => StoreLicense(
    plainText(json, 'spdx', json.string('spdx')),
    attribution: optPlainText(
      json,
      'attribution',
      json.optString('attribution'),
    ),
    file: optPlainText(json, 'file', json.optString('file')),
  );

  /// The SPDX licence id, or `LicenseRef-…` for a custom one.
  final String spdx;

  /// The credit line users must show, when the licence requires one.
  final String? attribution;

  /// The licence text's file inside the package.
  final String? file;

  /// This licence as JSON.
  Map<String, Object?> toJson() =>
      compactJson({'spdx': spdx, 'attribution': attribution, 'file': file});
}

/// Who made an item.
final class StoreAuthor {
  /// An author called [name], with an optional homepage.
  const StoreAuthor(this.name, {this.url});

  /// Reads one from [json].
  factory StoreAuthor.fromJson(JsonFields json) => StoreAuthor(
    plainText(json, 'name', json.string('name')),
    url: optPlainText(json, 'url', json.optString('url')),
  );

  /// Their name.
  final String name;

  /// Their homepage.
  final String? url;

  /// This author as JSON.
  Map<String, Object?> toJson() => compactJson({'name': name, 'url': url});
}

/// What an item costs. Reserved for paid items; v1 catalogs are all free.
final class StorePricing {
  /// A price, in [currency]'s minor units (cents) when paid.
  const StorePricing({
    this.model = PricingModel.free,
    this.amount,
    this.currency,
    this.licence,
  });

  /// Free.
  static const StorePricing free = StorePricing();

  /// Reads one from [json].
  factory StorePricing.fromJson(JsonFields json) {
    final model = json.choice(
      'model',
      PricingModel.byId,
      fallback: PricingModel.free,
    );
    final pricing = StorePricing(
      model: model,
      amount: json.optInt('amount'),
      currency: json.optString('currency'),
      licence: json.optString('licence'),
    );
    if (model == PricingModel.paid &&
        (pricing.amount == null || pricing.currency == null)) {
      throw json.error('amount', 'A paid item needs an amount and currency.');
    }
    return pricing;
  }

  /// Free or paid.
  final PricingModel model;

  /// The price in minor units (cents), for paid items.
  final int? amount;

  /// The ISO 4217 currency code, for paid items.
  final String? currency;

  /// `per-seat` or `per-project`, for paid items.
  final String? licence;

  /// Whether it costs nothing.
  bool get isFree => model == PricingModel.free;

  /// This pricing as JSON.
  Map<String, Object?> toJson() => compactJson({
    'model': model.name,
    'amount': amount,
    'currency': currency,
    'licence': licence,
  });
}

/// Counts a catalog's CI works out each night.
final class StoreStats {
  /// [downloads] and [likes].
  const StoreStats({this.downloads = 0, this.likes = 0});

  /// Reads them from [json].
  factory StoreStats.fromJson(JsonFields json) => StoreStats(
    downloads: json.optInt('downloads') ?? 0,
    likes: json.optInt('likes') ?? 0,
  );

  /// How many times its archives were downloaded.
  final int downloads;

  /// Reactions on its discussion.
  final int likes;

  /// These stats as JSON.
  Map<String, Object?> toJson() => {'downloads': downloads, 'likes': likes};
}

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
      if (!StoreNames.isId(dep)) {
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
    final idProblem = StoreNames.idProblem(id);
    if (idProblem != null) throw json.error('id', idProblem);
    final kind = json.choice('kind', ItemKind.byId);
    final category = json.string('category');
    if (!StoreNames.isCategory(category)) {
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
      sourceRepo: optPlainText(json, 'sourceRepo', json.optString('sourceRepo')),
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

/// A heading items are grouped under, and the folder they install into.
final class StoreCategory {
  /// The category [id], shown as [label], sorted by [order].
  const StoreCategory(this.id, this.label, {this.order = 100});

  /// Reads one from [json].
  factory StoreCategory.fromJson(JsonFields json) {
    final id = json.string('id');
    if (!StoreNames.isCategory(id)) {
      throw json.error('id', '"$id" is not a category id.');
    }
    return StoreCategory(
      id,
      plainText(json, 'label', json.string('label')),
      order: json.optInt('order') ?? 100,
    );
  }

  /// Its id, used in folder names.
  final String id;

  /// Its display name.
  final String label;

  /// Where it sorts; lower first.
  final int order;

  /// This category as JSON.
  Map<String, Object?> toJson() => {'id': id, 'label': label, 'order': order};
}

/// Who serves a catalog.
final class StoreSourceInfo {
  /// The source [id], shown as [name].
  const StoreSourceInfo(this.id, this.name, {this.homepage});

  /// Reads one from [json].
  factory StoreSourceInfo.fromJson(JsonFields json) {
    final id = json.string('id');
    if (!_sourceId.hasMatch(id)) {
      throw json.error(
        'id',
        'A source id is lowercase letters, digits, ".", "_" and "-".',
      );
    }
    return StoreSourceInfo(
      id,
      plainText(json, 'name', json.string('name')),
      homepage: optPlainText(json, 'homepage', json.optString('homepage')),
    );
  }

  static final RegExp _sourceId = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

  /// Its id, recorded in the lockfile beside what came from it.
  final String id;

  /// Its display name.
  final String name;

  /// Its web page.
  final String? homepage;

  /// This source as JSON.
  Map<String, Object?> toJson() =>
      compactJson({'id': id, 'name': name, 'homepage': homepage});
}

/// An item the store took down — malware, a stolen asset — and why. It is
/// no longer offered, and projects that installed it are warned.
final class RemovedItem {
  /// [id] was removed for [reason].
  const RemovedItem(this.id, this.reason);

  /// Reads one from [json].
  factory RemovedItem.fromJson(JsonFields json) {
    final id = json.string('id');
    final problem = StoreNames.idProblem(id);
    if (problem != null) throw json.error('id', problem);
    return RemovedItem(id, plainText(json, 'reason', json.string('reason')));
  }

  /// The item's id.
  final String id;

  /// Why, in a sentence.
  final String reason;

  /// This removal as JSON.
  Map<String, Object?> toJson() => {'id': id, 'reason': reason};
}

/// A catalog: what a store source offers. It is published as a small
/// `index.json` naming pieces (see `CatalogFiles`), or — small catalogs,
/// tests — as one `index.json` listing every item, which [fromJson] reads.
final class StoreIndex {
  /// A catalog from [source] listing [items] under [categories]. Use
  /// [StoreIndex.checked] for items not yet checked against each other.
  StoreIndex({
    required this.source,
    required this.categories,
    required this.items,
    this.generatedAt,
    this.removed = const [],
    this.skipped = const [],
    this.featured = const [],
  }) : _byId = {for (final i in items) i.id: i};

  /// A catalog of [items], once no id is listed twice and every item's
  /// category is one of [categories] (which come out sorted). Throws
  /// [StoreFormatException] naming the item as `items[N]`.
  factory StoreIndex.checked({
    required StoreSourceInfo source,
    required List<StoreCategory> categories,
    required List<StoreItem> items,
    DateTime? generatedAt,
    List<RemovedItem> removed = const [],
    List<String> skipped = const [],
    List<String> featured = const [],
  }) {
    _check(items, categories);
    return StoreIndex(
      source: source,
      categories: [...categories]..sort((a, b) => a.order.compareTo(b.order)),
      items: items,
      generatedAt: generatedAt,
      removed: removed,
      skipped: skipped,
      featured: featured,
    );
  }

  static void _check(List<StoreItem> items, List<StoreCategory> categories) {
    final ids = <String>{};
    final known = {for (final c in categories) c.id};
    for (var i = 0; i < items.length; i++) {
      if (!ids.add(items[i].id)) {
        throw StoreFormatException(
          '"${items[i].id}" is listed twice.',
          where: 'items[$i].id',
        );
      }
      if (!known.contains(items[i].category)) {
        throw StoreFormatException(
          'Category "${items[i].category}" is not in "categories".',
          where: 'items[$i].category',
        );
      }
    }
  }

  /// The ids of the items left out because this version doesn't know their
  /// kind: an older store reading a newer catalog.
  final List<String> skipped;

  /// The newest catalog format this code reads.
  static const int currentSchema = 2;

  /// Reads a catalog that lists its items itself. Throws
  /// [StoreFormatException], also for a catalog split into pieces, which
  /// only a store source can read.
  factory StoreIndex.fromJson(JsonFields json) {
    final schema = json.integer('schema', min: 1);
    if (schema > currentSchema) {
      throw json.error(
        'schema',
        'This catalog needs a newer Asset Store (format $schema; this one '
            'reads up to $currentSchema).',
      );
    }
    if (json.has('pieces')) {
      throw json.error(
        'pieces',
        'This catalog is split into pieces; read it through its source.',
      );
    }
    final categories = categoriesFrom(json);
    final skipped = <String>[];
    final items = itemsFrom(json, skipped);
    _check(items, categories);
    return StoreIndex(
      source: StoreSourceInfo.fromJson(json.object('source')),
      categories: categories..sort((a, b) => a.order.compareTo(b.order)),
      items: items,
      generatedAt: json.optTime('generatedAt'),
      removed: removedFrom(json),
      skipped: skipped,
      featured: featuredFrom(json),
    );
  }

  /// The ids listed at `featured` in [json]: any that is not an id is left
  /// out (it names nothing).
  static List<String> featuredFrom(JsonFields json) => [
    for (final id in json.strings('featured'))
      if (StoreNames.isId(id)) id,
  ];

  /// The categories listed at `categories` in [json].
  static List<StoreCategory> categoriesFrom(JsonFields json) => [
    for (final c in json.objects('categories')) StoreCategory.fromJson(c),
  ];

  /// The removals listed at `removed` in [json].
  static List<RemovedItem> removedFrom(JsonFields json) => [
    for (final r in json.objects('removed')) RemovedItem.fromJson(r),
  ];

  /// The items listed at `items` in [json]. An item of a kind this version
  /// doesn't know (a newer catalog's) is left out, its id added to
  /// [skipped] — not a reason to refuse the whole catalog.
  static List<StoreItem> itemsFrom(JsonFields json, List<String> skipped) => [
    for (final i in json.objects('items'))
      if (i.raw('kind') case final String k
          when k.isNotEmpty && !ItemKind.byId.containsKey(k))
        ?_skip(i, skipped)
      else
        StoreItem.fromJson(i),
  ];

  static StoreItem? _skip(JsonFields item, List<String> skipped) {
    skipped.add('${item.raw('id')}');
    return null;
  }

  /// [text] parsed as a catalog that lists its items itself. Throws
  /// [StoreFormatException].
  factory StoreIndex.parse(String text) =>
      StoreIndex.fromJson(JsonFields.parse(text));

  /// Who serves it.
  final StoreSourceInfo source;

  /// Its categories, sorted.
  final List<StoreCategory> categories;

  /// Its items.
  final List<StoreItem> items;

  /// When it was built.
  final DateTime? generatedAt;

  /// What the store took down.
  final List<RemovedItem> removed;

  /// The ids of the items its makers show first, in order: the website's
  /// featured shelf. An id it doesn't list names nothing.
  final List<String> featured;

  /// The [featured] items it lists, in order.
  List<StoreItem> get featuredItems => [
    for (final id in featured) ?_byId[id],
  ];

  final Map<String, StoreItem> _byId;

  /// The item with [id], or null.
  StoreItem? item(String id) => _byId[id];

  /// Why the item [id] was taken down, when it was.
  RemovedItem? removal(String id) {
    for (final r in removed) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// The category with [id], or null.
  StoreCategory? category(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// This catalog as one JSON object listing every item.
  Map<String, Object?> toJson() => compactJson({
    'schema': currentSchema,
    'source': source.toJson(),
    'generatedAt': generatedAt?.toUtc().toIso8601String(),
    'categories': [for (final c in categories) c.toJson()],
    'items': [for (final i in items) i.toJson()],
    'removed': [for (final r in removed) r.toJson()],
    'featured': featured.isEmpty ? null : featured,
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
  // A path relative to index.json: no climbing out, no absolute paths.
  if (url.startsWith('/') ||
      url.contains(r'\') ||
      url.split('/').contains('..')) {
    throw json.error(key, '"$url" must stay beside index.json.');
  }
}
