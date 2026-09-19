import 'dart:async';

import 'package:engine/engine.dart' as engine;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';
import '../../core/profile/profile_repository.dart';
import '../body/body_repository.dart';
import '../fuel/targets_repository.dart';
import 'proposals_repository.dart';

final _log = Logger('proposals');

/// What to write for a `targets` proposal, or null when nothing is due.
///
/// Pulled out of [ProposalKeeper] so the decision is testable on its own —
/// same reasoning as the note on `carb_shift_wiring_test.dart`: the engine's
/// arithmetic (`engine.proposeCalorieChange`) is tested in packages/engine,
/// so this is the wiring around it, and the wiring is what actually breaks.
({String rationale, Map<String, dynamic> payload})? buildTargetsProposal({
  required List<engine.TrendPoint> trend,
  required String phaseWire,
  required NutritionTarget target,
  double? bmr,
}) {
  final proposal = engine.proposeCalorieChange(
    trend: trend,
    phase: engine.WeightPhase.fromWire(phaseWire),
    currentKcal: target.kcal,
  );
  if (proposal == null) return null;

  // `proposeCalorieChange` clamps the *step* to the spec's 100–150 kcal
  // window, but not the BMR floor — that lives in `dailyTarget`, a different
  // function, used when a target is set from scratch rather than nudged.
  // Docs/PLAN.md §11: "Engine floors: kcal ≥ estimated BMR" applies here
  // just as much, so it is enforced here instead of trusting the step clamp
  // to have covered it.
  if (bmr != null && proposal.toKcal < bmr) return null;

  final carbDeltaG = proposal.deltaKcal / engine.kcalPerGramCarb;
  final direction = proposal.deltaKcal < 0 ? 'down' : 'up';
  final rationale =
      'Your trend has been ${proposal.observedRatePercent.toStringAsFixed(2)}% '
      'BW/week against a ${proposal.targetRatePercent.toStringAsFixed(2)}% '
      'target for two weeks, so calories should move $direction by '
      '${proposal.deltaKcal.abs().round()} — ${proposal.fromKcal} to '
      '${proposal.toKcal} kcal.';

  return (
    rationale: rationale,
    payload: {
      'fromKcal': proposal.fromKcal,
      'toKcal': proposal.toKcal,
      'proteinG': target.proteinG,
      'fatG': target.fatG,
      'carbG': target.carbG + carbDeltaG,
      'observedRatePercent': proposal.observedRatePercent,
      'targetRatePercent': proposal.targetRatePercent,
    },
  );
}

/// Watches the weight trend and today's target, and proposes a calorie
/// change when they have sat off the phase's band for long enough.
///
/// Same shape as `RollupKeeper` in rollup_repository.dart on purpose: listen
/// rather than watch, coalesce a burst of changes into one recompute, log
/// failures rather than throw. The maths is `engine.proposeCalorieChange` —
/// already written, already tested — docs/PLAN.md §6's "two weeks off
/// target, then ±100–150 kcal with the maths shown." This class only decides
/// when to ask for it and what to do with the answer.
class ProposalKeeper extends Notifier<void> {
  static const _coalesce = Duration(milliseconds: 400);

  Timer? _pending;
  var _synced = false;

  @override
  void build() {
    ref.listen(syncStatusProvider, (_, next) {
      final synced = next.value?.hasSynced == true;
      if (synced && !_synced) schedule();
      _synced = synced;
    });
    ref.listen(weightTrendProvider, (_, _) => schedule());
    ref.listen(todayTargetProvider, (_, _) => schedule());
    ref.onDispose(() => _pending?.cancel());
    schedule();
  }

  void schedule() {
    _pending?.cancel();
    _pending = Timer(_coalesce, refresh);
  }

  Future<void> refresh() async {
    try {
      await _refresh();
    } catch (e, stack) {
      _log.severe('Could not check for a calorie proposal', e, stack);
    }
  }

  Future<void> _refresh() async {
    // Same reasoning as RollupKeeper: recomputing against a half-downloaded
    // database would judge a trend it cannot see all of yet.
    if (ref.read(syncStatusProvider).value?.hasSynced != true) return;

    final target = ref.read(todayTargetProvider);
    final phaseWire = ref.read(profileProvider).value?.phase;
    if (target == null || phaseWire == null) return;

    final built = buildTargetsProposal(
      trend: ref.read(weightTrendProvider),
      phaseWire: phaseWire,
      target: target,
      bmr: ref.read(bmrProvider),
    );
    if (built == null) return;

    final proposals = ref.read(proposalsRepositoryProvider);
    if (await proposals.hasPending('targets')) return;

    await proposals.create(
      kind: 'targets',
      payload: built.payload,
      rationale: built.rationale,
      // `buildTargetsProposal` *is* the engine validation this kind needs —
      // the step clamp from `proposeCalorieChange` plus the BMR floor it
      // checks itself. There is no separate validator to call.
      validated: true,
    );
  }
}

final proposalKeeperProvider = NotifierProvider<ProposalKeeper, void>(
  ProposalKeeper.new,
);
