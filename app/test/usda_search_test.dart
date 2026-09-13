import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overload/features/fuel/usda_search_service.dart';

/// Reading USDA FoodData Central.
///
/// No network: the client is scripted, which is how the Open Food Facts
/// service is tested too.

const _chicken = {
  'foods': [
    {
      'fdcId': 171077,
      'description': 'CHICKEN, BROILERS OR FRYERS, BREAST, MEAT ONLY, RAW',
      'foodNutrients': [
        {'nutrientNumber': '208', 'value': 114},
        {'nutrientNumber': '203', 'value': 21.2},
        {'nutrientNumber': '205', 'value': 0},
        {'nutrientNumber': '204', 'value': 2.59},
        {'nutrientNumber': '291', 'value': 0},
        {'nutrientNumber': '307', 'value': 45},
      ],
    },
  ],
};

UsdaSearchService _service(
  Object body, {
  int status = 200,
  void Function(http.Request)? onRequest,
  String apiKey = 'test-key',
}) =>
    UsdaSearchService(
      apiKey: apiKey,
      client: MockClient((request) async {
        onRequest?.call(request);
        return http.Response(jsonEncode(body), status,
            headers: {'content-type': 'application/json'});
      }),
    );

void main() {
  test('reads nutrients by number, which is what is stable', () {
    // The names change; 208 has been calories for decades.
    return _service(_chicken).search('chicken breast').then((results) {
      expect(results.length, 1);
      final chicken = results.single;
      expect(chicken.kcalPer100, 114);
      expect(chicken.proteinPer100, 21.2);
      expect(chicken.fatPer100, 2.59);
      expect(chicken.sodiumMgPer100, 45);
      expect(chicken.source, 'usda');
      expect(chicken.sourceId, '171077');
    });
  });

  test('softens a description that is shouted', () async {
    final results = await _service(_chicken).search('chicken');
    expect(results.single.name, 'Chicken, Broilers Or Fryers, Breast, Meat Only, Raw');
  });

  test('leaves an ordinary description alone', () async {
    final results = await _service({
      'foods': [
        {
          'fdcId': 1,
          'description': 'Rice, white, long-grain, raw',
          'foodNutrients': [
            {'nutrientNumber': '208', 'value': 365},
          ],
        },
      ],
    }).search('rice');
    expect(results.single.name, 'Rice, white, long-grain, raw');
  });

  test('asks only for whole foods, because OFF has the packaged ones', () async {
    Uri? asked;
    await _service(_chicken, onRequest: (r) => asked = r.url).search('chicken');
    expect(asked!.queryParameters['dataType'], 'Foundation,SR Legacy');
    expect(asked!.queryParameters['query'], 'chicken');
  });

  test('a food with no calories is not a food anyone can log', () async {
    // Guessing them from the macros would be inventing a number.
    final results = await _service({
      'foods': [
        {
          'fdcId': 2,
          'description': 'Water',
          'foodNutrients': [
            {'nutrientNumber': '203', 'value': 0},
          ],
        },
      ],
    }).search('water');
    expect(results, isEmpty);
  });

  test('no key means no request at all, and no error', () async {
    var called = false;
    final service = UsdaSearchService(
      apiKey: '',
      client: MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );

    expect(service.configured, isFalse);
    expect(await service.search('chicken'), isEmpty);
    expect(called, isFalse);
  });

  test('a failure is an empty list, not an exception', () async {
    // A search box that throws is a search box nobody trusts, and the local
    // list is already on screen.
    expect(await _service(_chicken, status: 429).search('chicken'), isEmpty);
    expect(await _service('not json at all').search('chicken'), isEmpty);
  });

  test('a query too short to mean anything is not sent', () async {
    var called = false;
    final service = UsdaSearchService(
      apiKey: 'k',
      client: MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );
    expect(await service.search('c'), isEmpty);
    expect(called, isFalse);
  });
}
