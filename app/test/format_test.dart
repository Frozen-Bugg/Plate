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
}
