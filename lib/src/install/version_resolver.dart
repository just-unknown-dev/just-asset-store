/// Picking a version of every item a plan touches.
library;

import 'package:just_core_cli/just_core_cli.dart';
import 'package:just_core_cli/project.dart';
import 'package:meta/meta.dart';

import '../catalog/item_traits.dart';
import '../catalog/store_item.dart';
import '../lockfile/store_lock.dart';
import 'install_plan.dart';
import 'project_state.dart';
import 'store_catalog.dart';

/// Picks a version for every item a plan touches, going back on a choice
/// when it leads nowhere.
///
/// What constrains an item: what was asked for ("you"), the installed
/// items the plan keeps (by their manifests), and the versions it picks
/// (by the catalog). An installed item the plan replaces stops
/// constraining anything: its new version speaks for it. Installed items
/// are kept while they fit, and replaced only when they must.
@internal
final class VersionResolver {
  /// A resolver for [targets], over [catalog] and the project's [state],
  /// naming items with [nameOf].
  VersionResolver(
    this.catalog,
    this.state,
    this.targets, {
    required this.nameOf,
  });

  /// What the sources offer.
  final StoreCatalog catalog;

  /// What the project has.
  final ProjectState state;

  /// What was asked for.
  final Map<String, VersionConstraint> targets;

  /// An item's name, for the messages.
  final String Function(String id) nameOf;

  /// Each decided item: the catalog version picked, or null to keep what
  /// is installed (or a developer's checkout).
  final Map<String, StoreItemVersion?> decided = {};

  PlanIssue? _failure;
  var _failureDepth = -1;
  var _steps = 0;
  var _gaveUp = false;

  /// How many choices it tries before it says it cannot settle them.
  static const int maxSteps = 20000;

  ProjectState get _state => state;
  StoreCatalog get _catalog => catalog;

  /// Why no plan was found: the problem met deepest into the search.
  PlanIssue get failure => _gaveUp || _failure == null
      ? const PlanIssue(
          IssueLevel.blocker,
          'The items depend on each other in a way the store cannot settle.',
        )
      : _failure!;

  /// Every item's decision, or null when none fits.
  Map<String, StoreItemVersion?>? solve() => _search(0) ? decided : null;

  /// The picked versions that need [id].
  List<String> neededBy(String id) => [
    for (final e in decided.entries)
      if (e.key != id && (e.value?.dependencies.containsKey(id) ?? false))
        nameOf(e.key),
  ];

  /// The items to decide, in the order they come up: what was asked for,
  /// then what the picked versions need.
  List<String> _wanted() {
    final out = [...targets.keys];
    final seen = out.toSet();
    for (final v in decided.values) {
      if (v == null) continue;
      for (final dep in v.dependencies.keys.toList()..sort()) {
        if (seen.add(dep)) out.add(dep);
      }
    }
    return out;
  }

  /// What asks [id] for which versions, and who.
  List<(VersionConstraint, String)> _constraintsOn(String id) {
    final out = <(VersionConstraint, String)>[];
    final target = targets[id];
    if (target != null) out.add((target, 'you'));
    for (final other in _state.lock.items.keys) {
      if (other == id || decided[other] != null) continue;
      final c = _state.dependenciesOf(other)[id];
      if (c != null) out.add((c, nameOf(other)));
    }
    decided.forEach((other, v) {
      if (other == id || v == null) return;
      final c = v.dependencies[id];
      if (c != null) out.add((c, nameOf(other)));
    });
    return out;
  }

  bool _search(int depth) {
    if (++_steps > maxSteps) {
      _gaveUp = true;
      return false;
    }
    final wanted = _wanted();
    // A choice made earlier that what was picked since rules out.
    for (final id in wanted) {
      if (!decided.containsKey(id)) continue;
      final problem = _misfit(id, decided[id], _constraintsOn(id));
      if (problem != null) {
        _fail(depth, problem);
        return false;
      }
    }
    final next = wanted.where((id) => !decided.containsKey(id)).firstOrNull;
    if (next == null) return true;
    final (options, problem) = _options(next, _constraintsOn(next));
    if (options.isEmpty) {
      _fail(depth, problem!);
      return false;
    }
    for (final option in options) {
      decided[next] = option;
      if (_search(depth + 1)) return true;
      decided.remove(next);
      if (_gaveUp) return false;
    }
    return false;
  }

  void _fail(int depth, PlanIssue problem) {
    if (depth > _failureDepth) {
      _failureDepth = depth;
      _failure = problem;
    }
  }

  /// Whether the item kept ([option] null) or picked fails [constraints].
  PlanIssue? _misfit(
    String id,
    StoreItemVersion? option,
    List<(VersionConstraint, String)> constraints,
  ) {
    final Version? version;
    if (option != null) {
      version = option.version;
    } else {
      final locked = _state.lock.items[id];
      // A checkout, or a pub.dev library: pub checks those.
      if (locked == null || locked.origin != ItemOrigin.vendored) return null;
      version = _state.installedVersion(id);
    }
    if (version == null || constraints.every((c) => c.$1.allows(version!))) {
      return null;
    }
    return _noFit(id, constraints);
  }

  /// What [id] may be, best first, or why it may be nothing.
  (List<StoreItemVersion?>, PlanIssue?) _options(
    String id,
    List<(VersionConstraint, String)> constraints,
  ) {
    final locked = _state.lock.items[id];
    final isTarget = targets.containsKey(id);
    final name = nameOf(id);
    // A developer's own checkout stays as it is.
    if (locked?.origin == ItemOrigin.linked ||
        (locked == null && _state.foreignOverrides.containsKey(id))) {
      if (!isTarget) return (const [null], null);
      return (
        const <StoreItemVersion?>[],
        PlanIssue(
          IssueLevel.blocker,
          '$name comes from your own checkout; update it there.',
          id: id,
        ),
      );
    }
    final installed = _state.installedVersion(id);
    final keep =
        locked != null &&
        !isTarget &&
        (locked.origin == ItemOrigin.hosted ||
            (installed != null &&
                constraints.every((c) => c.$1.allows(installed))));
    final entry = _catalog.entry(id);
    if (entry == null) {
      if (keep) return (const [null], null);
      return (
        const <StoreItemVersion?>[],
        PlanIssue(
          IssueLevel.blocker,
          '"$id" (needed by ${constraints.map((c) => c.$2).join(', ')}) is '
          'not in any of your sources.',
          id: id,
        ),
      );
    }
    final item = entry.item;
    if (item.kind == ItemKind.template) {
      if (keep) return (const [null], null);
      return (
        const <StoreItemVersion?>[],
        PlanIssue(
          IssueLevel.blocker,
          '${item.name} is a project template, not something to install: '
          'start a project from it with `just create <folder> --template '
          '${item.id}`.',
          id: id,
        ),
      );
    }
    if (item.unavailable) {
      if (keep) return (const [null], null);
      return (
        const <StoreItemVersion?>[],
        PlanIssue(
          IssueLevel.blocker,
          '${item.name} is no longer offered: its repository was removed '
          'or changed hands.',
          id: id,
        ),
      );
    }
    final versions = [
      for (final v in item.available)
        if (constraints.every((c) => c.$1.allows(v.version)) &&
            !(keep && v.version == installed))
          v,
    ]..sort(_preference);
    final options = <StoreItemVersion?>[if (keep) null, ...versions];
    if (options.isEmpty) return (options, _noFit(id, constraints));
    return (options, null);
  }

  /// Versions this project can run before those it can't, releases before
  /// pre-releases, newest first.
  int _preference(StoreItemVersion a, StoreItemVersion b) {
    final fa = _runsHere(a), fb = _runsHere(b);
    if (fa != fb) return fa ? -1 : 1;
    final pa = a.version.isPreRelease, pb = b.version.isPreRelease;
    if (pa != pb) return pa ? 1 : -1;
    return b.version.compareTo(a.version);
  }

  bool _runsHere(StoreItemVersion v) => v.requires.entries.every((e) {
    final have = _state.environment[e.key];
    return have == null || e.value.allows(have);
  });

  PlanIssue _noFit(String id, List<(VersionConstraint, String)> constraints) {
    final item = _catalog.entry(id)?.item;
    final available = [
      for (final v in item?.available ?? const <StoreItemVersion>[])
        '${v.version}',
    ];
    final why = constraints
        .map(
          (c) =>
              c.$2 == 'you' ? 'you asked for ${c.$1}' : '${c.$2} needs ${c.$1}',
        )
        .join('; ');
    return PlanIssue(
      IssueLevel.blocker,
      'No version of ${nameOf(id)} fits: $why. '
      '${available.isEmpty ? 'None is available.' : 'Available: ${available.join(', ')}.'}',
      id: id,
    );
  }
}
