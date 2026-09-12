import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/core/sync/sync_rejections.dart';

SyncRejection rejection({String table = 'sets', String code = '23514'}) =>
    SyncRejection(
      id: 'id-$table-$code',
      rejectedTable: table,
      rowId: 'row',
      op: 'put',
      code: code,
      message: 'rejected',
      occurredAt: DateTime.utc(2026, 9, 12),
      acknowledged: false,
    );

void main() {
  group('describeRejection', () {
    test('translates the codes the schema can actually produce', () {
      expect(describeRejection(rejection(code: '23505')),
          'A record for that already existed on the server.');
      expect(describeRejection(rejection(code: '23502')),
          'A required field was empty.');
      expect(describeRejection(rejection(code: '23514')),
          'A value was outside the range the server allows.');
      expect(describeRejection(rejection(code: '42501')),
          'The server would not let this account write it.');
    });

    test('covers the whole data-exception class, not just the ones listed', () {
      expect(describeRejection(rejection(code: '22007')),
          'A value had the wrong type.');
      expect(describeRejection(rejection(code: '22P02')),
          'A value had the wrong type.');
    });

    test('says something useful for a code nobody anticipated', () {
      expect(describeRejection(rejection(code: '40001')),
          'The server refused it.');
    });
  });

  group('summariseRejections', () {
    test('names what was lost, in the words the app uses elsewhere', () {
      expect(summariseRejections([rejection()]), '1 set');
      expect(
        summariseRejections([rejection(), rejection()]),
        '2 sets',
      );
      expect(
        summariseRejections([rejection(table: 'body_metrics')]),
        '1 weigh-in',
      );
      expect(
        summariseRejections([rejection(table: 'recovery_daily')]),
        '1 check-in',
      );
    });

    test('joins several tables readably', () {
      final summary = summariseRejections([
        rejection(),
        rejection(),
        rejection(table: 'body_metrics'),
      ]);
      expect(summary, contains('2 sets'));
      expect(summary, contains('1 weigh-in'));
      expect(summary, contains(' and '));
    });

    test('falls back to the table name rather than inventing one', () {
      expect(summariseRejections([rejection(table: 'coach_threads')]),
          '1 coach_threads');
    });

    test('handles nothing at all', () {
      expect(summariseRejections([]), 'nothing');
    });
  });
}
