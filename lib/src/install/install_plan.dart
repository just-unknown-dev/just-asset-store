/// A plan: the changes an install, update or uninstall would make, and
/// what the user should know first.
library;

import '../catalog/item_traits.dart';
import '../catalog/store_item.dart';
import '../lockfile/store_lock.dart';
import '../project/store_project.dart';
import 'planner.dart';
import 'store_catalog.dart';

/// What a plan does to one item.
enum ChangeKind {
  /// Not installed yet.
  install,

  /// Installed; another version replaces it.
  update,

  /// Taken out of the project.
  remove,

  /// Installed already, as another item's dependency, and now on purpose
  /// too: it joins the project's own dependencies, so it stays when what
  /// needed it goes. Nothing is downloaded or replaced.
  adopt,
}

/// One item a plan changes.
final class PlannedChange {
  /// [kind] for [id].
  const PlannedChange({
    required this.id,
    required this.kind,
    required this.itemKind,
    required this.reason,
    this.entry,
    this.version,
    this.current,
    this.direct = true,
  });

  /// The item's id.
  final String id;

  /// What happens to it.
  final ChangeKind kind;

  /// What it is.
  final ItemKind itemKind;

  /// Why: "you asked", "needed by …", "no longer needed".
  final String reason;

  /// Where it comes from, for installs and updates.
  final CatalogEntry? entry;

  /// The version going in, for installs and updates.
  final StoreItemVersion? version;

  /// What is installed now, for updates, removals and adoptions.
  final LockedItem? current;

  /// Installed on purpose rather than as another item's dependency.
  final bool direct;

  /// The item's display name.
  String get name => entry?.item.name ?? id;

  /// The folder it goes in (vendored items): `plugins/{category}/{id}` for
  /// an editor extension or a kit, `packages/{category}/{id}` for content.
  String? get path {
    final category = entry?.item.category ?? current?.category;
    if (!itemKind.isVendored || category == null) return current?.path;
    return StoreProject.itemPath(itemKind, category, id);
  }

  /// Whether new code comes in or goes: the editor restarts to load it.
  bool get needsRestart => kind != ChangeKind.adopt && itemKind.needsRestart;
}

/// How much an issue matters.
enum IssueLevel {
  /// The plan cannot be applied.
  blocker,

  /// Applying it is allowed, after the user has seen this.
  warning,

  /// Worth knowing.
  info,
}

/// Something about a plan the user should see.
final class PlanIssue {
  /// [message] at [level], about item [id].
  const PlanIssue(this.level, this.message, {this.id});

  /// How much it matters.
  final IssueLevel level;

  /// What, in a sentence or two.
  final String message;

  /// The item it concerns.
  final String? id;

  @override
  String toString() => '${level.name}: $message';
}

/// What an install, update or uninstall would do: shown in the preview,
/// then handed to the installer.
final class InstallPlan {
  /// [changes] with [issues], worked out from [catalog].
  const InstallPlan(this.changes, this.issues, {this.catalog});

  /// The items it changes.
  final List<PlannedChange> changes;

  /// What the user should know, blockers first.
  final List<PlanIssue> issues;

  /// The catalog it was planned from, when a [Planner] made it: the
  /// installer checks each package against it (a package must not depend
  /// on a store item it doesn't declare).
  final StoreCatalog? catalog;

  /// Whether it can be applied: no blockers, something to do.
  bool get canApply =>
      changes.isNotEmpty && !issues.any((i) => i.level == IssueLevel.blocker);

  /// The blockers.
  Iterable<PlanIssue> get blockers =>
      issues.where((i) => i.level == IssueLevel.blocker);

  /// Whether the editor must restart afterwards: code changes.
  bool get needsRestart => changes.any((c) => c.needsRestart);

  /// The bytes to download (archives not cached may be fewer).
  int get downloadBytes => changes.fold(
    0,
    (sum, c) =>
        sum +
        (c.kind == ChangeKind.adopt || c.kind == ChangeKind.remove
            ? 0
            : c.version?.archive?.size ?? 0),
  );

  /// The bytes it unpacks into the project, as the catalog says
  /// ([StoreArchive.unpackedSize], else the archive's size).
  int get unpackedBytes => changes.fold(
    0,
    (sum, c) =>
        sum +
        (c.kind == ChangeKind.adopt || c.kind == ChangeKind.remove
            ? 0
            : c.version?.archive?.unpackedSize ??
                  c.version?.archive?.size ??
                  0),
  );

  /// A plan unpacking more than this into the project says so first
  /// ([unpackedBytes]): 1 GiB.
  static const int largeUnpack = 1 << 30;

  /// This plan with [more] issues too: blockers first, then warnings, then
  /// the rest, each in the order they came.
  InstallPlan withIssues(Iterable<PlanIssue> more) {
    final all = [...issues, ...more];
    return InstallPlan(changes, [
      for (final level in IssueLevel.values)
        ...all.where((i) => i.level == level),
    ], catalog: catalog);
  }
}
