import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/format.dart';

void main() {
  group('formatWeight', () {
    test('drops trailing zeros on whole numbers', () {
      expect(formatWeight(60), '60 kg');
      expect(formatWeight(60.0), '60 kg');
    });

    test('keeps the half on plate-sized increments', () {
      expect(formatWeight(62.5), '62.5 kg');
      expect(formatWeight(2.5), '2.5 kg');
    });

    test('rounds away floating point noise from engine arithmetic', () {
      // 100 * (1 - 0.10) lands just under 90 in binary floating point.
      expect(formatWeight(100 * (1 - 0.10)), '90 kg');
    });

    test('handles zero', () {
      expect(formatWeight(0), '0 kg');
    });
  });

  group('formatRir', () {
    test('shows whole numbers without a decimal', () {
      expect(formatRir(2), 'RIR 2');
      expect(formatRir(0), 'RIR 0');
    });

    test('keeps a half when the lifter rated between', () {
      expect(formatRir(1.5), 'RIR 1.5');
    });
  });

  group('formatWeeklyRate', () {
    test('signs the direction', () {
      expect(formatWeeklyRate(-0.6), '−0.6 kg/week');
      expect(formatWeeklyRate(0.3), '+0.3 kg/week');
    });

    test('calls a rate under 50 g a week what it is', () {
      expect(formatWeeklyRate(0.02), 'Holding steady');
      expect(formatWeeklyRate(-0.04), 'Holding steady');
      expect(formatWeeklyRate(0), 'Holding steady');
    });

    test('rounds to the tenth a scale can actually support', () {
      expect(formatWeeklyRate(-0.6449), '−0.6 kg/week');
    });
  });

  group('formatPlate', () {
    test('says plates the way a lifter does', () {
      expect(formatPlate(25), '25');
      expect(formatPlate(2.5), '2.5');
      expect(formatPlate(1.25), '1.25');
    });
  });
}
