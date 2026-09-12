import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'foods_repository.dart';

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

  static const _host = 'world.openfoodfacts.org';

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

    final url = Uri.https(_host, '/cgi/search.pl', {
      'search_terms': term,
      'search_simple': '1',
      'action': 'process',
      'json': '1',
      'page_size': '$limit',
      'fields': _fields,
    });

    try {
      final response = await _client.get(url).timeout(_timeout);
      if (response.statusCode != 200) {
        _log.info('Food search returned ${response.statusCode}');
        return const [];
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final products = (body['products'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      return [
        for (final product in products)
          ?_toFacts(product),
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
      final response = await _client.get(url).timeout(_timeout);
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

    final brand = (product['brands'] as String?)
        ?.split(',')
        .first
        .trim();

    return FoodFacts(
      name: name,
      brand: brand == null || brand.isEmpty ? null : brand,
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
final onlineFoodSearchProvider =
    FutureProvider.family<List<FoodFacts>, String>((ref, query) async {
  if (query.trim().length < 2) return const [];
  return ref.watch(foodSearchServiceProvider).search(query);
});
