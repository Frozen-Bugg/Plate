import 'package:engine/engine.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/train/progression_repository.dart';

TemplateExercise row({
  int sets = 3,
  int repMin = 8,
  int repMax = 12,
  double? targetRir = 2,
  String model = 'double',
}) {
  final now = DateTime.utc(2026, 9, 12);
  return TemplateExercise(
    id: 'te-1',
    createdAt: now,
    updatedAt: now,
    userId: 'u-1',
    templateId: 't-1',
    exerciseId: 'e-1',
    position: 0,
    sets: sets,
    repMin: repMin,
    repMax: repMax,
    targetRir: targetRir,
    progressionModel: model,
  );
}

void main() {
  test('reads the rep range and effort the template prescribes', () {
    final p = Prescription.fromTemplate(row(repMin: 5, repMax: 8, targetRir: 1));
    expect(p.repMin, 5);
    expect(p.repMax, 8);
    expect(p.targetRir, 1);
  });

  test('maps the stored model name', () {
    expect(
      Prescription.fromTemplate(row(model: 'linear')).model,
      engine.ProgressionModel.linear,
    );
    expect(
      Prescription.fromTemplate(row(model: 'double')).model,
      engine.ProgressionModel.double_,
    );
  });

  // A bad value in the database should not cost the lifter their target.
  test('an unknown model falls back to double rather than throwing', () {
    expect(
      Prescription.fromTemplate(row(model: 'nonsense')).model,
      engine.ProgressionModel.double_,
    );
  });

  test('a template with no target effort leaves the gate open', () {
    // Null targetRir means the rep range alone decides, which is what the
    // engine's DoubleProgression does with a null targetRir.
    expect(Prescription.fromTemplate(row(targetRir: null)).targetRir, isNull);
  });

  test('carries the planned set count', () {
    expect(Prescription.fromTemplate(row(sets: 5)).sets, 5);
  });

  test('the default prescription is the spec example range', () {
    const p = Prescription();
    expect(p.repMin, 8);
    expect(p.repMax, 12);
    expect(p.targetRir, 2);
    expect(p.model, engine.ProgressionModel.double_);
  });
}
