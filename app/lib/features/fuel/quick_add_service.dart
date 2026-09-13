import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_config.dart';

/// One food the coach read out of a sentence.
///
/// Every number here is an estimate a model made. Nothing is logged until the
/// lifter has seen it itemised and agreed — docs/PLAN.md §11.
class ParsedItem {
  ParsedItem({
    required this.name,
    required this.quantity,
    required this.unit,
    required this.estimatedGrams,
    required this.kcal,
    required this.proteinG,
    required this.carbG,
    required this.fatG,
    this.note,
  }) : grams = estimatedGrams;

  final String name;
  final double quantity;
  final String unit;

  /// What the coach thought the whole amount weighed. Fixed, because the
  /// per-100 figures are derived from it: if this moved with the edit below,
  /// correcting 200 g to 100 g would halve the portion *and* double the
  /// density, and the calories would not change at all.
  final double estimatedGrams;

  /// The amount actually being logged. Editable — it is the one field the
  /// schema stores, and rescaling everything from it means a lifter who knows
  /// it was three eggs rather than four fixes the whole item with one number.
  double grams;

  final double kcal;
  final double proteinG;
  final double carbG;
  final double fatG;

  /// The assumption worth arguing with — "assumed large", or a warning that
  /// the macros do not add up to the calories.
  final String? note;

  /// What the coach believed per 100 g, which is what a `Food` row stores.
  ///
  /// Derived from [estimatedGrams], never from the edited amount — the density
  /// of an egg does not change because the lifter had three of them.
  double get kcalPer100 => _per100(kcal);
  double get proteinPer100 => _per100(proteinG);
  double get carbPer100 => _per100(carbG);
  double get fatPer100 => _per100(fatG);

  double _per100(double total) =>
      estimatedGrams <= 0 ? 0 : total / estimatedGrams * 100;

  /// The totals for the amount currently entered.
  double get scaledKcal => kcalPer100 * grams / 100;
  double get scaledProteinG => proteinPer100 * grams / 100;
  double get scaledCarbG => carbPer100 * grams / 100;
  double get scaledFatG => fatPer100 * grams / 100;

  /// How it was said, for the line under the name: "4 items", "200 g".
  String get said =>
      unit == 'g' || unit == 'ml'
          ? '${quantity.round()} $unit'
          : '${_trim(quantity)} ${quantity == 1 ? unit : '${unit}s'}';

  static String _trim(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  factory ParsedItem.fromJson(Map<String, dynamic> json) => ParsedItem(
        name: json['name'] as String? ?? 'Food',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 1,
        unit: json['unit'] as String? ?? 'item',
        estimatedGrams: (json['grams'] as num?)?.toDouble() ?? 0,
        kcal: (json['kcal'] as num?)?.toDouble() ?? 0,
        proteinG: (json['proteinG'] as num?)?.toDouble() ?? 0,
        carbG: (json['carbG'] as num?)?.toDouble() ?? 0,
        fatG: (json['fatG'] as num?)?.toDouble() ?? 0,
        note: (json['note'] as String?)?.trim().isEmpty ?? true
            ? null
            : json['note'] as String,
      );
}

class ParsedMeal {
  const ParsedMeal({required this.slot, required this.items});

  final String slot;
  final List<ParsedItem> items;
}

/// One set heard out of a sentence, before it is confirmed.
///
/// `sets` is how many identical ones — "three by eight at eighty" is one of
/// these with sets 3, not three of them, because that is how a lifter says it
/// and how they will want to correct it.
class ParsedSet {
  ParsedSet({
    required this.exercise,
    required this.weightKg,
    required this.reps,
    required this.sets,
    this.rir,
  });

  final String exercise;
  double weightKg;
  int reps;
  int sets;
  double? rir;

  factory ParsedSet.fromJson(Map<String, dynamic> json) => ParsedSet(
        exercise: json['exercise'] as String? ?? 'Exercise',
        weightKg: (json['weightKg'] as num?)?.toDouble() ?? 0,
        reps: (json['reps'] as num?)?.toInt() ?? 0,
        sets: (json['sets'] as num?)?.toInt() ?? 1,
        rir: (json['rir'] as num?)?.toDouble(),
      );
}

/// Raised when the sentence could not be turned into food.
class QuickAddError implements Exception {
  const QuickAddError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Sends a sentence to the Coach API and gets back itemised food.
class QuickAddService {
  QuickAddService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// One model call with no tools, so this is quick. Long enough that a cold
  /// function start does not look like a failure.
  static const _timeout = Duration(seconds: 45);

  Future<ParsedMeal> parse(String text, {required String slot}) async {
    final json = await _post('parse-food', {'text': text, 'slot': slot});
    return _mealFrom(json, slot);
  }

  /// Reads a photo of a plate or a label.
  ///
  /// [note] is anything the lifter typed alongside it — "the rice is half a
  /// cup" is the cheapest accuracy available, and a picture cannot say it.
  Future<ParsedMeal> parsePhoto({
    required Uint8List bytes,
    required String mediaType,
    required String slot,
    String? note,
  }) async {
    final json = await _post('parse-photo', {
      'image': base64Encode(bytes),
      'mediaType': mediaType,
      'slot': slot,
      if (note != null && note.trim().isNotEmpty) 'text': note.trim(),
    });
    return _mealFrom(json, slot);
  }

  /// Reads a sentence about lifting into sets, for confirmation.
  Future<List<ParsedSet>> parseSets(String text) async {
    final json = await _post('parse-sets', {'text': text});
    final list = json is List ? json : const [];
    return [
      for (final set in list)
        ParsedSet.fromJson((set as Map).cast<String, dynamic>()),
    ];
  }

  ParsedMeal _mealFrom(dynamic json, String fallback) {
    final map = (json as Map).cast<String, dynamic>();
    return ParsedMeal(
      slot: map['slot'] as String? ?? fallback,
      items: [
        for (final item in (map['items'] as List<dynamic>? ?? const []))
          ParsedItem.fromJson((item as Map).cast<String, dynamic>()),
      ],
    );
  }

  Future<dynamic> _post(String route, Map<String, dynamic> body) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) throw const QuickAddError('You are signed out.');

    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('${AppConfig.supabaseUrl}/functions/v1/coach/$route'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (_) {
      throw const QuickAddError(
        'Could not reach the coach. Reading a meal needs a connection — '
        'searching your own foods does not.',
      );
    }

    if (response.statusCode != 200) throw QuickAddError(_explain(response));
    return jsonDecode(response.body);
  }

  /// 422 is the parser saying the sentence was not food, and its message is
  /// written for the lifter. Anything else is ours and reads like it.
  static String _explain(http.Response response) {
    String? detail;
    try {
      detail = (jsonDecode(response.body) as Map<String, dynamic>)['error']
          as String?;
    } catch (_) {
      detail = null;
    }
    if (response.statusCode == 422 && detail != null) return detail;
    return switch (response.statusCode) {
      401 => 'Your session expired. Sign in again.',
      404 => 'The coach is not deployed yet.',
      429 => 'The model is busy. Try again in a minute.',
      _ => detail ?? 'The coach could not read that (${response.statusCode}).',
    };
  }
}

final quickAddServiceProvider = Provider<QuickAddService>(
  (ref) => QuickAddService(),
);
