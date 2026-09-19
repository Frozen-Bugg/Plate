import 'package:engine/engine.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../fuel/targets_repository.dart';
import 'proposals_repository.dart';

/// Changes the coach has proposed, waiting for an answer.
///
/// Docs/PLAN.md §7: "Diff card + reasoning → Accept / Reject; everything is
/// undoable." A proposal is never applied by being written — see
/// proposals_repository.dart — so accepting here is two writes: apply the
/// change through whatever repository already owns that table, then mark the
/// proposal answered.
class ProposalsScreen extends ConsumerWidget {
  const ProposalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proposals = ref.watch(pendingProposalsProvider).value ?? const [];
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('Proposals')),
      body: proposals.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Nothing waiting. The coach proposes a change here when '
                  'your trend has sat off target for a couple of weeks — '
                  'you always get to say yes or no.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: muted),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final proposal in proposals)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ProposalCard(proposal: proposal),
                  ),
              ],
            ),
    );
  }
}

class _ProposalCard extends ConsumerStatefulWidget {
  const _ProposalCard({required this.proposal});

  final AiProposal proposal;

  @override
  ConsumerState<_ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends ConsumerState<_ProposalCard> {
  var _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await _apply(ref, widget.proposal);
      await ref.read(proposalsRepositoryProvider).accept(widget.proposal.id);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not apply that: $e')));
      }
    }
  }

  Future<void> _decline() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _DeclineDialog(),
    );
    if (reason == null) return;
    setState(() => _busy = true);
    await ref
        .read(proposalsRepositoryProvider)
        .decline(widget.proposal.id, reason: reason.isEmpty ? null : reason);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final proposal = widget.proposal;
    final payload = payloadOf(proposal);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _kindLabel(proposal.kind),
              style: text.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 6),
            if (proposal.kind == 'targets') _TargetsDiff(payload: payload),
            const SizedBox(height: 8),
            Text(
              proposal.rationale,
              style: text.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _decline,
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _accept,
                    child: Text(_busy ? 'Applying…' : 'Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _kindLabel(String kind) => switch (kind) {
    'targets' => 'CALORIE TARGET',
    'deload' => 'DELOAD',
    'program_change' => 'PROGRAM CHANGE',
    'meal_plan' => 'MEAL PLAN',
    'exercise_swap' => 'EXERCISE SWAP',
    _ => kind.toUpperCase(),
  };
}

/// Applies an accepted proposal through whatever repository already owns
/// that table. Only `targets` exists yet — see proposals_repository.dart and
/// the plan this shipped from for why the others are not here.
Future<void> _apply(WidgetRef ref, AiProposal proposal) async {
  switch (proposal.kind) {
    case 'targets':
      final payload = payloadOf(proposal);
      await ref
          .read(targetsRepositoryProvider)
          .save(
            target: engine.MacroTarget(
              kcal: (payload['toKcal'] as num).round(),
              proteinG: (payload['proteinG'] as num).round(),
              carbG: (payload['carbG'] as num).round(),
              fatG: (payload['fatG'] as num).round(),
              flooredAtBmr: false,
            ),
            source: 'coach',
          );
    default:
      throw StateError('No apply step for "${proposal.kind}" yet.');
  }
}

class _TargetsDiff extends StatelessWidget {
  const _TargetsDiff({required this.payload});

  final Map<String, dynamic> payload;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final from = (payload['fromKcal'] as num?)?.round();
    final to = (payload['toKcal'] as num?)?.round();
    if (from == null || to == null) return const SizedBox.shrink();

    return Row(
      children: [
        Text(
          '$from',
          style: text.titleMedium?.copyWith(
            decoration: TextDecoration.lineThrough,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Icon(Icons.arrow_forward, size: 16),
        ),
        Text('$to kcal', style: text.titleMedium),
      ],
    );
  }
}

class _DeclineDialog extends StatefulWidget {
  const _DeclineDialog();

  @override
  State<_DeclineDialog> createState() => _DeclineDialogState();
}

class _DeclineDialogState extends State<_DeclineDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Decline this one?'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Why (optional)',
          hintText: 'Not this week',
        ),
        onSubmitted: (_) => Navigator.of(context).pop(_controller.text.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Decline'),
        ),
      ],
    );
  }
}
