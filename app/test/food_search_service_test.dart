import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overload/features/fuel/food_search_service.dart';

/// Open Food Facts is crowd-sourced, so the interesting cases are all the ways
/// a product can be half-filled in rather than the happy path.
FoodSearchService serving(Object body, {int status = 200}) => FoodSearchService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

Map<String, dynamic> product({
  String? name = 'Greek Yoghurt',
  /// A String from the product endpoint, a List from the search service.
  Object? brands = 'Fage, Total',
  String code = '5201054003014',
  Map<String, dynamic>? nutriments,
  Object? servingQuantity = 170,
  String? servingSize = '170 g',
}) =>
    {
      'code': code,
      'product_name': name,
      'brands': brands,
      'serving_quantity': servingQuantity,
      'serving_size': servingSize,
      'nutriments': nutriments ??
          {
            'energy-kcal_100g': 97,
            'proteins_100g': 9,
            'carbohydrates_100g': 3.6,
            'fat_100g': 5,
            'fiber_100g': 0,
            'sugars_100g': 3.6,
            'saturated-fat_100g': 3.4,
            'sodium_100g': 0.036,
          },
    };

void main() {
  group('search', () {
    test('maps a well-filled product', () async {
      final results = await serving({
        'hits': [product()],
      }).search('yoghurt');

      expect(results, hasLength(1));
      final food = results.single;
      expect(food.name, 'Greek Yoghurt');
      // Only the first brand: OFF stores a pile of them.
      expect(food.brand, 'Fage');
      expect(food.source, 'off');
      expect(food.sourceId, '5201054003014');
      expect(food.barcode, '5201054003014');
      expect(food.kcalPer100, 97);
      expect(food.proteinPer100, 9);
      expect(food.servingG, 170);
      expect(food.servingLabel, '170 g');
    });

    test('converts sodium from grams to milligrams', () async {
      final food = (await serving({
        'hits': [product()],
      }).search('yoghurt'))
          .single;
      expect(food.sodiumMgPer100, closeTo(36, 1e-9));
    });

    test('falls back to kilojoules when there is no kcal figure', () async {
      final food = (await serving({
        'hits': [
          product(nutriments: {'energy_100g': 406}),
        ],
      }).search('yoghurt'))
          .single;
      expect(food.kcalPer100, closeTo(406 / 4.184, 0.01));
    });

    test('drops a product with no name', () async {
      final results = await serving({
        'hits': [product(name: null), product(name: '  ')],
      }).search('yoghurt');
      expect(results, isEmpty);
    });

    test('drops a product with no energy, rather than logging a zero', () async {
      final results = await serving({
        'hits': [
          product(nutriments: {'proteins_100g': 9}),
        ],
      }).search('yoghurt');
      expect(results, isEmpty);
    });

    test('drops an energy figure no food could have', () async {
      final results = await serving({
        'hits': [
          product(nutriments: {'energy-kcal_100g': 4000}),
        ],
      }).search('yoghurt');
      expect(results, isEmpty);
    });

    test('treats an impossible macro as missing rather than refusing the food',
        () async {
      // 150 g of protein per 100 g is a data-entry slip, not a superfood. The
      // calories are still usable, so the food is offered with the macro zeroed
      // rather than thrown away.
      final food = (await serving({
        'hits': [
          product(nutriments: {
            'energy-kcal_100g': 97,
            'proteins_100g': 150,
            'carbohydrates_100g': 3.6,
          }),
        ],
      }).search('yoghurt'))
          .single;
      expect(food.proteinPer100, 0);
      expect(food.carbPer100, 3.6);
    });

    test('keeps only barcodes that look like barcodes', () async {
      final food = (await serving({
        'hits': [product(code: 'abc')],
      }).search('yoghurt'))
          .single;
      expect(food.barcode, isNull);
      // The source id still records where it came from.
      expect(food.sourceId, 'abc');
    });

    test('ignores a serving size that is not a serving', () async {
      final food = (await serving({
        'hits': [product(servingQuantity: 90000)],
      }).search('yoghurt'))
          .single;
      expect(food.servingG, isNull);
    });

    test('parses numbers that arrive as strings', () async {
      final food = (await serving({
        'hits': [
          product(nutriments: {
            'energy-kcal_100g': '97',
            'proteins_100g': '9',
          }),
        ],
      }).search('yoghurt'))
          .single;
      expect(food.kcalPer100, 97);
      expect(food.proteinPer100, 9);
    });

    test('reads brands whether they arrive as a list or a string', () async {
      // The search service returns a list; the product endpoint returns one
      // comma-separated string. Getting this wrong made every search silently
      // return nothing, because the cast threw and the catch swallowed it.
      final fromList = (await serving({
        'hits': [
          product(brands: ['Quaker', ' Quaker Oats']),
        ],
      }).search('oats'))
          .single;
      expect(fromList.brand, 'Quaker');

      final fromString =
          (await serving({'hits': [product(brands: 'Fage, Total')]})
                  .search('yoghurt'))
              .single;
      expect(fromString.brand, 'Fage');
    });

    test('copes with a product that names no brand at all', () async {
      for (final brands in [null, '', <String>[], '  ']) {
        final food = (await serving({
          'hits': [product(brands: brands)],
        }).search('yoghurt'))
            .single;
        expect(food.brand, isNull, reason: 'for $brands');
      }
    });

    test('reads the search service shape as well as the older one', () async {
      expect(await serving({'hits': [product()]}).search('xy'), hasLength(1));
      expect(await serving({'products': [product()]}).search('xy'), hasLength(1));
    });

    test('says nothing for a one-letter query rather than fetching the world',
        () async {
      var called = false;
      final service = FoodSearchService(
        client: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      expect(await service.search('e'), isEmpty);
      expect(called, isFalse);
    });

    test('returns nothing when the service is unhappy', () async {
      expect(await serving({'products': []}, status: 500).search('xy'), isEmpty);
    });

    test('returns nothing rather than throwing when the network is gone',
        () async {
      final service = FoodSearchService(
        client: MockClient((_) async => throw const SocketExceptionStub()),
      );
      expect(await service.search('yoghurt'), isEmpty);
    });

    test('survives a body that is not the shape it promised', () async {
      expect(await serving({'products': 'nonsense'}).search('xy'), isEmpty);
      expect(await serving({'unexpected': true}).search('xy'), isEmpty);
    });
  });

  group('byBarcode', () {
    test('reads the product when the scan finds one', () async {
      final food = await serving({
        'status': 1,
        'product': product(),
      }).byBarcode('5201054003014');
      expect(food, isNotNull);
      expect(food!.name, 'Greek Yoghurt');
    });

    test('is null when the barcode is unknown', () async {
      final food = await serving({'status': 0}).byBarcode('0000000000000');
      expect(food, isNull);
    });
  });
}

/// A stand-in for a connection failure, since dart:io is not available to a
/// Flutter test on every platform this suite runs on.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
