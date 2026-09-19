import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

/// Changes the coach wants to make, waiting for an answer.
///
/// Docs/PLAN.md §7: "the only route from the coach to a change." Nothing here
/// is applied by being written — see `ai_proposals` in the migration. Writing
/// a row only ever creates the card; accepting one is a separate write, made
/// by whatever screen knows how to apply that `kind` of change (the Proposals
/// screen, for `targets`).
class ProposalsRepository {
  ProposalsRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<List<AiProposal>> watchPending() {
    return (_db.select(_db.aiProposals)
          ..where((p) => p.userId.equals(_userId))
          ..where((p) => p.status.equals('pending'))
          ..where((p) => p.deletedAt.isNull())
          ..orderBy([(p) => OrderingTerm.desc(p.createdAt)]))
        .watch();
  }

  /// Whether a `kind` proposal is already waiting for an answer.
  ///
  /// Checked before creating another. `ProposalKeeper` re-evaluates on every
  /// change to the trend or the target, and without this guard the same drift
  /// would file a fresh card every time it fired rather than one that sits
  /// there until answered.
  Future<bool> hasPending(String kind) async {
    final rows =
        await (_db.select(_db.aiProposals)
              ..where((p) => p.userId.equals(_userId))
              ..where((p) => p.kind.equals(kind))
              ..where((p) => p.status.equals('pending'))
              ..where((p) => p.deletedAt.isNull())
              ..limit(1))
            .get();
    return rows.isNotEmpty;
  }

  /// Writes a proposal. [validated] must only be true when whatever built
  /// [payload] already enforced the engine's own limits for that kind — an
  /// unvalidated proposal must never be offered (see the migration).
  Future<String> create({
    required String kind,
    required Map<String, dynamic> payload,
    required String rationale,
    bool validated = false,
    String? validationNotes,
  }) async {
    final id = uuid.v7();
    await _db
        .into(_db.aiProposals)
        .insert(
          AiProposalsCompanion.insert(
            id: Value(id),
            userId: _userId,
            kind: kind,
            payload: jsonEncode(payload),
            rationale: Value(rationale),
            validated: Value(validated),
            validationNotes: Value(validationNotes),
          ),
        );
    return id;
  }

  Future<void> accept(String id) => _respond(id, status: 'accepted');

  Future<void> decline(String id, {String? reason}) =>
      _respond(id, status: 'declined', declineReason: reason);

  Future<void> _respond(
    String id, {
    required String status,
    String? declineReason,
  }) => (_db.update(_db.aiProposals)..where((p) => p.id.equals(id))).write(
    AiProposalsCompanion(
      status: Value(status),
      respondedAt: Value(nowUtc()),
      declineReason: Value(declineReason),
      updatedAt: Value(nowUtc()),
    ),
  );
}

final proposalsRepositoryProvider = Provider<ProposalsRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('ProposalsRepository used while signed out');
  }
  return ProposalsRepository(ref.watch(appDatabaseProvider), user.id);
});

final pendingProposalsProvider = StreamProvider<List<AiProposal>>(
  (ref) => ref.watch(proposalsRepositoryProvider).watchPending(),
);

/// Reads a proposal's payload back as a map. Same defensive shape as
/// `coach_repository.dart`'s `chipsOf` — a row written by a newer version
/// should still open rather than crash the inbox.
Map<String, dynamic> payloadOf(AiProposal proposal) {
  try {
    return (jsonDecode(proposal.payload) as Map).cast<String, dynamic>();
  } catch (_) {
    return const {};
  }
}
