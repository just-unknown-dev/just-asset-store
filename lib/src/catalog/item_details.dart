/// What a catalog says of an item besides its versions: its licence,
/// author, price and numbers.
library;

import 'package:just_core_cli/just_core_cli.dart';

import 'item_traits.dart';
import 'plain_text.dart';

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
