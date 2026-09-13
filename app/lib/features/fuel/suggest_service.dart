import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'quick_add_service.dart';

/// One thing worth eating next.
///
/// The numbers came from the server, which worked them out from the log and
/// the ingredients — the model only chose the combinations. Logging one is
/// still a separate, deliberate tap: a suggestion is not a meal.
class Suggestion {
  const Suggestion({
    required this.name,
    required this.kcal,
    required this.proteinG,
    required this.carbG,
    required this.fatG,
    required this.why,
    this.fromPrep,
    this.fromRecipe,
  });

  factory Suggestion.fromJson(Map<String, dynamic> json) => Suggestion(
        name: json['name'] as String? ?? 'Something',
        kcal: _num(json['kcal']),
        proteinG: _num(json['proteinG']),
        carbG: _num(json['carbG']),
        fatG: _num(json['fatG']),
        why: json['why'] as String? ?? '',
        fromPrep: json['fromPrep'] as String?,
        fromRecipe: json['fromRecipe'] as String?,
      );

  final String name;
  final double kcal;
  final double proteinG;
  final double carbG;
  final double fatG;
  final String why;

  /// Names a batch already in the fridge, when that is what this is.
  final String? fromPrep;

  /// Names one of their saved recipes.
  final String? fromRecipe;

  /// Whether this is food that already exists, and so can be logged in a tap
  /// rather than typed in from scratch.
  bool get isCooked => fromPrep != null;
}

/// A remainder, and three things that would fit in it.
class Suggestions {
  const Suggestions({
    required this.options,
    this.leftKcal,
    this.leftProteinG,
    this.urgent,
  });

  factory Suggestions.fromJson(Map<String, dynamic> json) {
    final left = (json['left'] as Map?)?.cast<String, dynamic>();
    return Suggestions(
      leftKcal: left == null ? null : _num(left['kcal']),
      leftProteinG: left == null ? null : _num(left['proteinG']),
      urgent: json['urgent'] as String?,
      options: [
        for (final option in (json['options'] as List<dynamic>? ?? const []))
          Suggestion.fromJson((option as Map).cast<String, dynamic>()),
      ],
    );
  }

  /// Null when no target is set — which is different from nothing being left.
  final double? leftKcal;
  final double? leftProteinG;

  /// Food in the fridge that has to be eaten, said by the server rather than
  /// the model so it is true whatever the model replies.
  final String? urgent;

  final List<Suggestion> options;
}

/// Asks the coach what to eat next.
class SuggestService {
  SuggestService(this._quickAdd);

  final QuickAddService _quickAdd;

  /// [note] is anything the lifter typed — "I have got chicken and rice in",
  /// "something quick". Optional, and the reason there is no pantry table.
  Future<Suggestions> suggest({required String day, String? note}) async {
    final json = await _quickAdd.post('suggest', {
      'today': day,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
    });
    return Suggestions.fromJson((json as Map).cast<String, dynamic>());
  }
}

double _num(Object? value) => switch (value) {
      final num n => n.toDouble(),
      _ => 0,
    };

final suggestServiceProvider = Provider<SuggestService>(
  (ref) => SuggestService(ref.watch(quickAddServiceProvider)),
);
