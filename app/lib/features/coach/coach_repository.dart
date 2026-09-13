import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' show uuid;

import '../../core/auth/auth_service.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import 'coach_service.dart';

/// Conversations with the coach, and the turns in them.
///
/// The device owns these writes. The Coach API answers and streams; it never
/// touches the database. That keeps one write path — device, then PowerSync,
/// then Postgres — which is why a thread reads the same offline as online and
/// survives a request that fails halfway.
class CoachRepository {
  CoachRepository(this._db, this._userId);

  final AppDatabase _db;
  final String _userId;

  Stream<List<CoachThread>> watchThreads() {
    return (_db.select(_db.coachThreads)
          ..where((t) => t.userId.equals(_userId))
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.lastMessageAt),
            (t) => OrderingTerm.desc(t.createdAt),
          ]))
        .watch();
  }

  Stream<List<CoachMessage>> watchMessages(String threadId) {
    return (_db.select(_db.coachMessages)
          ..where((m) => m.threadId.equals(threadId))
          ..where((m) => m.deletedAt.isNull())
          ..orderBy([(m) => OrderingTerm.asc(m.position)]))
        .watch();
  }

  /// Starts a conversation and returns its id.
  ///
  /// Every non-nullable column is written explicitly: PowerSync creates the
  /// local tables without DEFAULT clauses (see CLAUDE.md).
  Future<String> startThread({String kind = 'chat'}) async {
    final id = uuid.v7();
    await _db.into(_db.coachThreads).insert(
          CoachThreadsCompanion.insert(
            id: Value(id),
            userId: _userId,
            kind: Value(kind),
          ),
        );
    return id;
  }

  /// The conversation in progress, or a new one.
  ///
  /// One running thread rather than a list to manage: this is a coach, not an
  /// inbox, and the question after "how is my bench" is nearly always about the
  /// same thing.
  Future<String> currentThread() async {
    final open = await (_db.select(_db.coachThreads)
          ..where((t) => t.userId.equals(_userId))
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(1))
        .get();
    return open.firstOrNull?.id ?? await startThread();
  }

  Future<String> addMessage({
    required String threadId,
    required String role,
    required String content,
    List<CoachChip> chips = const [],
    String? model,
    int? inputTokens,
    int? outputTokens,
    String? error,
  }) async {
    final existing = await (_db.select(_db.coachMessages)
          ..where((m) => m.threadId.equals(threadId))
          ..where((m) => m.deletedAt.isNull()))
        .get();

    final id = uuid.v7();
    await _db.into(_db.coachMessages).insert(
          CoachMessagesCompanion.insert(
            id: Value(id),
            userId: _userId,
            threadId: threadId,
            position: existing.length,
            role: role,
            content: Value(content),
            toolCalls: Value(jsonEncode([for (final c in chips) c.toJson()])),
            model: Value(model),
            inputTokens: Value(inputTokens),
            outputTokens: Value(outputTokens),
            error: Value(error),
          ),
        );

    await (_db.update(_db.coachThreads)..where((t) => t.id.equals(threadId)))
        .write(
      CoachThreadsCompanion(
        lastMessageAt: Value(nowUtc()),
        updatedAt: Value(nowUtc()),
      ),
    );
    return id;
  }

  /// Replaces a message's text and its chips.
  ///
  /// The assistant's row is written the moment the answer starts, so a turn
  /// that dies halfway leaves a visible half-answer rather than nothing, and
  /// then grows in place as the text arrives. PowerSync views cannot be
  /// upserted (see CLAUDE.md), so this is an update on a row that exists.
  Future<void> updateMessage(
    String id, {
    String? content,
    List<CoachChip>? chips,
    String? model,
    int? inputTokens,
    int? outputTokens,
    String? error,
  }) {
    return (_db.update(_db.coachMessages)..where((m) => m.id.equals(id))).write(
      CoachMessagesCompanion(
        content: content == null ? const Value.absent() : Value(content),
        toolCalls: chips == null
            ? const Value.absent()
            : Value(jsonEncode([for (final c in chips) c.toJson()])),
        model: model == null ? const Value.absent() : Value(model),
        inputTokens:
            inputTokens == null ? const Value.absent() : Value(inputTokens),
        outputTokens:
            outputTokens == null ? const Value.absent() : Value(outputTokens),
        error: Value(error),
        updatedAt: Value(nowUtc()),
      ),
    );
  }

  /// Soft delete, cascading by hand.
  ///
  /// Postgres cascades on a hard delete; this is a soft one, and without
  /// marking the messages too they stay forever, invisible to every screen and
  /// still syncing to every device.
  Future<void> deleteThread(String id) async {
    final now = nowUtc();
    await (_db.update(_db.coachMessages)
          ..where((m) => m.threadId.equals(id))
          ..where((m) => m.deletedAt.isNull()))
        .write(
      CoachMessagesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await (_db.update(_db.coachThreads)..where((t) => t.id.equals(id))).write(
      CoachThreadsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }
}

final coachRepositoryProvider = Provider<CoachRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('CoachRepository used while signed out');
  }
  return CoachRepository(ref.watch(appDatabaseProvider), user.id);
});

/// The conversation on screen. Resolved once, then held.
final currentThreadProvider = FutureProvider<String>(
  (ref) => ref.watch(coachRepositoryProvider).currentThread(),
);

final coachMessagesProvider =
    StreamProvider.family<List<CoachMessage>, String>(
  (ref, threadId) =>
      ref.watch(coachRepositoryProvider).watchMessages(threadId),
);

/// Reads the chips back off a stored message.
List<CoachChip> chipsOf(CoachMessage message) {
  try {
    final decoded = jsonDecode(message.toolCalls) as List<dynamic>;
    return [
      for (final chip in decoded)
        CoachChip.fromJson((chip as Map).cast<String, dynamic>()),
    ];
  } catch (_) {
    // A row written by a newer version, or a half-written one. The message
    // still reads fine without its chips.
    return const [];
  }
}
