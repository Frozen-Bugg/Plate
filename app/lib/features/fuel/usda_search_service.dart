import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../core/config/app_config.dart';
import 'foods_repository.dart';

final _log = Logger('usda-search');

/// Looks raw ingredients up in USDA FoodData Central.
///
/// The other half of the search. Open Food Facts is a database of *packaged*
/// food and is very good at it — scan a barcode and it knows the product. It is
/// much weaker on "chicken breast", "white rice, dry", "olive oil", which are
/// exactly what a recipe is made of.
///
/// So this asks only for Foundation and SR Legacy entries: laboratory-analysed
/// whole foods, per 100 g, no brands. Branded data is in FDC too and is
/// deliberately not requested — it would duplicate what OFF already answers
/// better, and two sources offering the same yoghurt is a worse search than one.
///
/// Needs an API key, free from fdc.nal.usda.gov/api-key-signup.html. Without
/// one the service reports itself unconfigured and the search simply does not
/// include it — no error, no empty section, nothing to explain.
class UsdaSearchService {
  UsdaSearchService({http.Client? client, String? apiKey})
      : _client = client ?? http.Client(),
        _apiKey = apiKey ?? AppConfig.usdaApiKey;

  final http.Client _client;
  final String _apiKey;

  static const _host = 'api.nal.usda.gov';

  /// Whole foods only. Branded is left to Open Food Facts.
  static const _dataTypes = 'Foundation,SR Legacy';

  /// The same short timeout as the other source, and for the same reason: a
  /// result that lands after the lifter has typed it by hand is worse than none.
  static const _timeout = Duration(seconds: 6);

  /// FDC nutrient numbers. Stable identifiers, unlike the names.
  static const _kcal = '208';
  static const _protein = '203';
  static const _carb = '205';
  static const _fat = '204';
  static const _fibre = '291';
  static const _sugar = '269';
  static const _satFat = '606';
  static const _sodium = '307';

  bool get configured => _apiKey.isNotEmpty;

  Future<List<FoodFacts>> search(String query, {int limit = 10}) async {
    final term = query.trim();
    if (!configured || term.length < 2) return const [];

    final url = Uri.https(_host, '/fdc/v1/foods/search', {
      'api_key': _apiKey,
      'query': term,
      'dataType': _dataTypes,
      'pageSize': '$limit',
    });

    try {
      final response = await _client.get(url).timeout(_timeout);
      if (response.statusCode != 200) {
        _log.info('USDA search returned ${response.statusCode}');
        return const [];
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final foods = body['foods'] as List<dynamic>? ?? const [];
      return [
        for (final food in foods)
          ?_toFacts((food as Map).cast<String, dynamic>()),
      ];
    } catch (e) {
      // Offline, rate-limited, or slow. The local list is already on screen.
      _log.info('USDA search failed: $e');
      return const [];
    }
  }

  /// FDC gives nutrients as a list rather than a map, keyed by number.
  static FoodFacts? _toFacts(Map<String, dynamic> food) {
    final name = (food['description'] as String?)?.trim();
    if (name == null || name.isEmpty) return null;

    final byNumber = <String, double>{};
    for (final entry in (food['foodNutrients'] as List<dynamic>? ?? const [])) {
      final row = (entry as Map).cast<String, dynamic>();
      final number = row['nutrientNumber']?.toString();
      final value = _number(row['value']);
      if (number != null && value != null) byNumber[number] = value;
    }

    final kcal = byNumber[_kcal];
    // Without calories it is not a food anyone can log, and guessing them from
    // the macros would be inventing a number.
    if (kcal == null || kcal <= 0 || kcal > 900) return null;

    // Foundation and SR Legacy are reported per 100 g, which is how the schema
    // stores nutrition — so there is no conversion here, and that is the point
    // of asking only for those two.
    return FoodFacts(
      name: _tidy(name),
      source: 'usda',
      sourceId: food['fdcId']?.toString(),
      kcalPer100: kcal,
      proteinPer100: byNumber[_protein] ?? 0,
      carbPer100: byNumber[_carb] ?? 0,
      fatPer100: byNumber[_fat] ?? 0,
      fibrePer100: byNumber[_fibre],
      sugarPer100: byNumber[_sugar],
      satFatPer100: byNumber[_satFat],
      sodiumMgPer100: byNumber[_sodium],
    );
  }

  /// FDC descriptions are written for a database: "Chicken, broilers or fryers,
  /// breast, meat only, raw". Readable enough, but shouted in capitals often
  /// enough to be worth softening.
  static String _tidy(String name) {
    if (name != name.toUpperCase()) return name;
    return name
        .split(' ')
        .map((word) => word.isEmpty
            ? word
            : word[0] + word.substring(1).toLowerCase())
        .join(' ');
  }

  static double? _number(Object? value) => switch (value) {
        final num n when n.isFinite => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };
}

final usdaSearchServiceProvider =
    Provider<UsdaSearchService>((ref) => UsdaSearchService());
