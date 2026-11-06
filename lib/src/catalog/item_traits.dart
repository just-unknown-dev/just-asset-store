/// What kind of item a catalog lists, and its traits: how far the store
/// vouches for it, what its code does, how finished it is, who may
/// download it, and whether it costs money.
library;

import 'package:just_core_cli/just_core_cli.dart';

import 'item_details.dart';

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
