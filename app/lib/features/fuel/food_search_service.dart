import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'foods_repository.dart';
import 'usda_search_service.dart';

final _log = Logger('food-search');

/// Looks foods up in Open Food Facts.
///
/// OFF is a public, key-free database of packaged food, which makes it the
/// right first source: no signup, no secret in the build, and it covers the
/// barcoded things people actually log. USDA FoodData Central covers raw
/// ingredients better but needs an API key, so it joins later behind the same
/// interface.
///
/// Nothing here is stored. A result becomes a row only when it is used, through
/// [FoodsRepository.remember] — see the migration for why the food database is
/// copied rather than synced.
class FoodSearchService {
  FoodSearchService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Product lookups by barcode still live on the main site.
  static const _host = 'world.openfoodfacts.org';

  /// Full-text search does not. The old `/cgi/search.pl` endpoint answers 503
  /// now, with or without a User-Agent — it has been superseded by this one,
  /// which is a different service with a different response shape.
  static const _searchHost = 'search.openfoodfacts.org';

  /// Open Food Facts asks callers to identify themselves, and throttles the
  /// ones that do not.
  static const _headers = {
    'User-Agent': 'Overload/0.1 (github.com/Frozen-Bugg/Plate)',
  };

  /// The fields worth asking for. OFF returns a great deal per product and the
  /// search endpoint is slow enough without carrying all of it over a phone
  /// connection.
  static const _fields =
      'code,product_name,brands,serving_quantity,serving_size,nutriments';

  /// A short timeout on purpose: this sits under a search box, and a result
  /// that arrives after the lifter has given up and typed it by hand is worse
  /// than no result. Local matches are already on screen either way.
  static const _timeout = Duration(seconds: 6);

  Future<List<FoodFacts>> search(String query, {int limit = 20}) async {
    final term = query.trim();
    if (term.length < 2) return const [];

    final url = Uri.https(_searchHost, '/search', {
      'q': term,
      'page_size': '$limit',
    });

    try {
      final response =
          await _client.get(url, headers: _headers).timeout(_timeout);
      if (response.statusCode != 200) {
        _log.info('Food search returned ${response.statusCode}');
        return const [];
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      // `hits` is the search service; `products` is the older shape, kept so a
      // fixture or a fallback endpoint still parses.
      final products =
          (body['hits'] ?? body['products']) as List<dynamic>? ?? const [];
      return [
        for (final product in products)
          ?_toFacts((product as Map).cast<String, dynamic>()),
      ];
    } catch (e) {
      // Offline, blocked, or slow. The local list is still there, and a search
      // box that throws is a search box nobody trusts.
      _log.info('Food search failed: $e');
      return const [];
    }
  }

  /// One product by barcode — the scanner's path, and the exact one OFF is best
  /// at.
  Future<FoodFacts?> byBarcode(String barcode) async {
    final url = Uri.https(_host, '/api/v2/product/$barcode.json', {
      'fields': _fields,
    });
    try {
      final response =
          await _client.get(url, headers: _headers).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['status'] != 1) return null;
      return _toFacts(body['product'] as Map<String, dynamic>);
    } catch (e) {
      _log.info('Barcode lookup failed: $e');
      return null;
    }
  }

  /// Maps a product to [FoodFacts], or null when it is not worth offering.
  ///
  /// OFF is crowd-sourced and plenty of entries are half-filled: no name, or no
  /// energy. A food with no calories in it is not a food the app can log, and
  /// showing it only to fail later wastes a tap.
  static FoodFacts? _toFacts(Map<String, dynamic> product) {
    final name = (product['product_name'] as String?)?.trim();
    if (name == null || name.isEmpty) return null;

    final nutriments =
        (product['nutriments'] as Map<String, dynamic>?) ?? const {};
    final kcal = _number(nutriments['energy-kcal_100g']) ??
        // Some entries carry kilojoules only.
        _fromKilojoules(_number(nutriments['energy_100g']));
    if (kcal == null || kcal <= 0 || kcal > 900) return null;

    return FoodFacts(
      name: name,
      brand: _brand(product['brands']),
      source: 'off',
      sourceId: product['code'] as String?,
      barcode: _barcode(product['code']),
      kcalPer100: kcal,
      proteinPer100: _clamp(_number(nutriments['proteins_100g'])),
      carbPer100: _clamp(_number(nutriments['carbohydrates_100g'])),
      fatPer100: _clamp(_number(nutriments['fat_100g'])),
      fibrePer100: _optional(_number(nutriments['fiber_100g'])),
      sugarPer100: _optional(_number(nutriments['sugars_100g'])),
      satFatPer100: _optional(_number(nutriments['saturated-fat_100g'])),
      sodiumMgPer100: _sodiumMg(nutriments['sodium_100g']),
      servingG: _serving(product),
      servingLabel: (product['serving_size'] as String?)?.trim(),
    );
  }

  /// The first brand, however this endpoint happens to spell them.
  ///
  /// The search service returns a list; the product endpoint returns one
  /// comma-separated string. Either way a food belongs to one brand as far as a
  /// lifter is concerned, and "Quaker, Quaker Oats, PepsiCo" on a list row is
  /// noise.
  static String? _brand(Object? value) {
    final first = switch (value) {
      final List<dynamic> list =>
        list.isEmpty ? null : list.first?.toString(),
      final String s => s.split(',').first,
      _ => null,
    };
    final trimmed = first?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static double? _number(Object? value) => switch (value) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };

  static double? _fromKilojoules(double? kj) =>
      kj == null ? null : kj / 4.184;

  /// Macros are per 100 g, so anything outside 0-100 is a broken entry rather
  /// than an unusual food.
  static double _clamp(double? value) =>
      value == null || value < 0 || value > 100 ? 0 : value;

  static double? _optional(double? value) =>
      value == null || value < 0 || value > 100 ? null : value;

  /// OFF reports sodium in grams; the schema stores milligrams.
  static double? _sodiumMg(Object? value) {
    final grams = _number(value);
    if (grams == null || grams < 0) return null;
    final mg = grams * 1000;
    return mg > 100000 ? null : mg;
  }

  /// The schema only accepts 6-14 digits, which is what a real barcode is.
  static String? _barcode(Object? code) {
    final text = code?.toString();
    if (text == null) return null;
    return RegExp(r'^[0-9]{6,14}$').hasMatch(text) ? text : null;
  }

  static double? _serving(Map<String, dynamic> product) {
    final quantity = _number(product['serving_quantity']);
    if (quantity == null || quantity < 0.1 || quantity > 5000) return null;
    return quantity;
  }
}

final foodSearchServiceProvider =
    Provider<FoodSearchService>((ref) => FoodSearchService());

/// Online results for a query, or an empty list when there is no connection,
/// no match, or nothing worth offering.
/// Both sources, asked at once.
///
/// Open Food Facts knows packaged food; USDA knows raw ingredients. They are
/// asked in parallel because together they are still one search box, and a
/// second round trip would double the wait for the half nobody was after.
///
/// Packaged results come first. Most searches are for something with a barcode,
/// and "Chicken, broilers or fryers, breast" above a brand of yoghurt would be
/// a worse list however good the data behind it is.
final onlineFoodSearchProvider =
    FutureProvider.family<List<FoodFacts>, String>((ref, query) async {
  if (query.trim().length < 2) return const [];

  final results = await Future.wait([
    ref.watch(foodSearchServiceProvider).search(query),
    ref.watch(usdaSearchServiceProvider).search(query),
  ]);

  // Same food from both sides: the packaged one wins, because it is the one
  // with a barcode behind it.
  final seen = <String>{};
  return [
    for (final list in results)
      for (final facts in list)
        if (seen.add(facts.name.trim().toLowerCase())) facts,
  ];
});
