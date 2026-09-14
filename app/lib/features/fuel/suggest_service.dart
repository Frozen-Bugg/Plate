import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/day.dart';
import 'foods_repository.dart';
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

/// One ingredient of a drafted recipe.
///
/// No macros, on purpose: the coach names foods and weights, and every number
/// comes from a food row on this device. See `coach-api/src/tools/draft.ts`.
class DraftIngredient {
  const DraftIngredient({required this.name, required this.grams, this.note});

  factory DraftIngredient.fromJson(Map<String, dynamic> json) =>
      DraftIngredient(
        name: json['name'] as String? ?? '',
        grams: _num(json['grams']),
        note: json['note'] as String?,
      );

  final String name;
  final double grams;
  final String? note;
}

class DraftedRecipe {
  const DraftedRecipe({
    required this.name,
    required this.servings,
    required this.ingredients,
    this.steps = const [],
  });

  factory DraftedRecipe.fromJson(Map<String, dynamic> json) => DraftedRecipe(
        name: json['name'] as String? ?? 'Recipe',
        servings: (json['servings'] as num?)?.round() ?? 1,
        steps: [
          for (final step in (json['steps'] as List<dynamic>? ?? const []))
            if (step is String && step.trim().isNotEmpty) step.trim(),
        ],
        ingredients: [
          for (final row in (json['ingredients'] as List<dynamic>? ?? const []))
            DraftIngredient.fromJson((row as Map).cast<String, dynamic>()),
        ],
      );

  final String name;
  final int servings;

  /// How to cook it, a step to an entry.
  final List<String> steps;
  final List<DraftIngredient> ingredients;
}

/// Asks the coach to draft a recipe from a description.
class DraftService {
  DraftService(this._quickAdd);

  final QuickAddService _quickAdd;

  Future<DraftedRecipe> draftRecipe(String description) async {
    final json = await _quickAdd.post('draft-recipe', {'text': description});
    return DraftedRecipe.fromJson((json as Map).cast<String, dynamic>());
  }

  /// Prices ingredients nothing on the shelf matched.
  ///
  /// docs/MEAL-PLANNING.md §3, option three: match, then Open Food Facts, then
  /// ask. Counting an unmatched ingredient as zero was the worse answer — zero
  /// is definitely wrong, where an estimate is approximately right and says so.
  Future<List<EstimatedFood>> estimate(List<String> names) async {
    final json = await _quickAdd.post('estimate-foods', {'names': names});
    // The route hands back a bare array; the {foods: …} wrapper is the model's
    // reply shape and is unwrapped server-side.
    final list = json is List ? json : const [];
    return [
      for (final row in list)
        EstimatedFood.fromJson((row as Map).cast<String, dynamic>()),
    ];
  }

  /// A week of cooking, worked out around what is already in the fridge.
  Future<PrepPlan> draftPlan({String? note}) async {
    final json = await _quickAdd.post('draft-plan', {
      'today': dayKey(),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
    });
    return PrepPlan.fromJson((json as Map).cast<String, dynamic>());
  }
}

final draftServiceProvider = Provider<DraftService>(
  (ref) => DraftService(ref.watch(quickAddServiceProvider)),
);

/// One batch in a week's plan.
class PlannedCook {
  const PlannedCook({
    required this.name,
    required this.servings,
    required this.saved,
    required this.ingredients,
    this.covers,
  });

  factory PlannedCook.fromJson(Map<String, dynamic> json) => PlannedCook(
        name: json['name'] as String? ?? 'Cook',
        servings: (json['servings'] as num?)?.round() ?? 1,
        saved: json['saved'] == true,
        covers: json['covers'] as String?,
        ingredients: [
          for (final row in (json['ingredients'] as List<dynamic>? ?? const []))
            DraftIngredient.fromJson((row as Map).cast<String, dynamic>()),
        ],
      );

  final String name;
  final int servings;

  /// Whether this names a recipe already saved, whose ingredients the device
  /// has and the server did not send back.
  final bool saved;
  final String? covers;
  final List<DraftIngredient> ingredients;
}

class PrepPlan {
  const PrepPlan({required this.cooks, this.note});

  factory PrepPlan.fromJson(Map<String, dynamic> json) => PrepPlan(
        note: json['note'] as String?,
        cooks: [
          for (final row in (json['cooks'] as List<dynamic>? ?? const []))
            PlannedCook.fromJson((row as Map).cast<String, dynamic>()),
        ],
      );

  final List<PlannedCook> cooks;
  final String? note;
}

/// Per-100 g nutrition the coach worked out for a food nobody has yet.
///
/// An estimate, and it stays labelled as one all the way to the screen — see
/// `coach-api/src/tools/estimate.ts`. Created with `source = 'coach'` when it is
/// eventually saved, which is what lets the app keep saying so afterwards.
class EstimatedFood {
  const EstimatedFood({
    required this.name,
    required this.kcalPer100,
    required this.proteinPer100,
    required this.carbPer100,
    required this.fatPer100,
    this.fibrePer100,
    this.note,
  });

  factory EstimatedFood.fromJson(Map<String, dynamic> json) => EstimatedFood(
        name: json['name'] as String? ?? '',
        kcalPer100: _num(json['kcalPer100']),
        proteinPer100: _num(json['proteinPer100']),
        carbPer100: _num(json['carbPer100']),
        fatPer100: _num(json['fatPer100']),
        fibrePer100:
            json['fibrePer100'] == null ? null : _num(json['fibrePer100']),
        note: json['note'] as String?,
      );

  final String name;
  final double kcalPer100;
  final double proteinPer100;
  final double carbPer100;
  final double fatPer100;
  final double? fibrePer100;
  final String? note;

  /// Ready to be remembered as a food, flagged as the coach's guess.
  FoodFacts get facts => FoodFacts(
        name: name,
        source: 'coach',
        kcalPer100: kcalPer100,
        proteinPer100: proteinPer100,
        carbPer100: carbPer100,
        fatPer100: fatPer100,
        fibrePer100: fibrePer100,
      );
}

/// The suggestions on offer, and whether they are being fetched.
class SuggestionsState {
  const SuggestionsState({
    this.day,
    this.suggestions,
    this.error,
    this.asking = false,
  });

  /// The day these were asked for. A new day is a new question.
  final String? day;
  final Suggestions? suggestions;
  final String? error;
  final bool asking;

  bool get isEmpty => suggestions == null;
}

/// Holds what the coach suggested until somebody asks for something else.
///
/// The sheet used to ask on every open, so glancing at the options and closing
/// it threw them away — reopening produced three different meals and no way
/// back to the one you had half-decided on. Suggestions are a *thing you were
/// given*, not a fresh roll of the dice, so they live here and outlive the
/// sheet.
///
/// Kept per day, and only for this run of the app. A day-old suggestion is
/// answering a question about a day that has finished, and a cold start is a
/// natural moment to ask again.
class SuggestionsNotifier extends Notifier<SuggestionsState> {
  @override
  SuggestionsState build() => const SuggestionsState();

  /// Fetches only when there is nothing usable — a fresh day, an error, or a
  /// first open. [force] is the refresh button, which is the "until asked"
  /// half of "it should not change until asked".
  Future<void> ensure({required String day, bool force = false}) async {
    if (state.asking) return;
    if (!force && state.day == day && state.suggestions != null) return;

    state = SuggestionsState(
      day: day,
      // Kept on screen while a refresh runs: a blank sheet loses the option
      // somebody was reading.
      suggestions: force ? state.suggestions : null,
      asking: true,
    );

    try {
      final result =
          await ref.read(suggestServiceProvider).suggest(day: day, note: _note);
      state = SuggestionsState(day: day, suggestions: result);
    } on QuickAddError catch (error) {
      state = SuggestionsState(day: day, error: error.message);
    } catch (_) {
      state = SuggestionsState(day: day, error: 'The coach could not answer.');
    }
  }

  String? _note;

  /// Asks again with something to work around — "chicken and rice in".
  Future<void> askWith({required String day, required String note}) {
    _note = note.trim().isEmpty ? null : note.trim();
    return ensure(day: day, force: true);
  }
}

final suggestionsProvider =
    NotifierProvider<SuggestionsNotifier, SuggestionsState>(
  SuggestionsNotifier.new,
);
