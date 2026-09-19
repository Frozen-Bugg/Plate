import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:overload/core/db/app_database.dart';
import 'package:overload/features/coach/proposals_repository.dart';

import 'support/test_database.dart';

void main() {
  const userId = 'u-1';

  late TestDatabase db;
  late ProposalsRepository proposals;

  setUp(() {
    db = TestDatabase();
    proposals = ProposalsRepository(db, userId);
  });

  tearDown(() => db.close());

  test('a created proposal shows up as pending', () async {
    await proposals.create(
      kind: 'targets',
      payload: {'fromKcal': 2400, 'toKcal': 2280},
      rationale: 'Trend has stalled for two weeks.',
      validated: true,
    );

    final pending = await proposals.watchPending().first;
    expect(pending, hasLength(1));
    expect(pending.single.kind, 'targets');
    expect(pending.single.rationale, 'Trend has stalled for two weeks.');
    expect(pending.single.validated, isTrue);
    expect(payloadOf(pending.single), {'fromKcal': 2400, 'toKcal': 2280});
  });

  test(
    'hasPending is true only while one of that kind is unanswered',
    () async {
      expect(await proposals.hasPending('targets'), isFalse);

      final id = await proposals.create(
        kind: 'targets',
        payload: const {},
        rationale: '',
      );
      expect(await proposals.hasPending('targets'), isTrue);
      expect(await proposals.hasPending('deload'), isFalse);

      await proposals.accept(id);
      expect(await proposals.hasPending('targets'), isFalse);
    },
  );

  test('accepting marks it answered and it leaves the pending list', () async {
    final id = await proposals.create(
      kind: 'targets',
      payload: const {},
      rationale: '',
    );

    await proposals.accept(id);

    final pending = await proposals.watchPending().first;
    expect(pending, isEmpty);
  });

  test('declining stores the reason', () async {
    final id = await proposals.create(
      kind: 'targets',
      payload: const {},
      rationale: '',
    );

    await proposals.decline(id, reason: 'Travelling this week');

    final row = await (db.select(
      db.aiProposals,
    )..where((p) => p.id.equals(id))).getSingle();
    expect(row.status, 'declined');
    expect(row.declineReason, 'Travelling this week');
    expect(row.respondedAt, isNotNull);
  });

  test('a proposal written by a newer version still opens', () async {
    // payloadOf must not throw on garbage — a row from a future version of
    // the app, or a half-written one, should still open the inbox.
    await db
        .into(db.aiProposals)
        .insert(
          AiProposalsCompanion.insert(
            id: const Value('p1'),
            userId: userId,
            kind: 'targets',
            payload: 'not json',
          ),
        );
    final row = await (db.select(
      db.aiProposals,
    )..where((p) => p.id.equals('p1'))).getSingle();
    expect(payloadOf(row), <String, dynamic>{});
  });
}
