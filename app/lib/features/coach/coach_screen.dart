import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../app/widgets/tab_scaffold.dart';
import '../../core/db/app_database.dart';
import 'coach_repository.dart';
import 'coach_service.dart';
import 'proposals_repository.dart';
import 'proposals_screen.dart';

/// The state of the answer being written right now.
///
/// Held separately from the stored messages: the row is written as soon as the
/// answer starts, but updating it in the database on every delta would be one
/// write per word. The text streams here and lands there once.
class Answering {
  const Answering({this.messageId, this.text = '', this.busy = false});

  final String? messageId;
  final String text;
  final bool busy;

  Answering copyWith({String? messageId, String? text, bool? busy}) =>
      Answering(
        messageId: messageId ?? this.messageId,
        text: text ?? this.text,
        busy: busy ?? this.busy,
      );
}

class CoachTurn extends Notifier<Answering> {
  @override
  Answering build() => const Answering();

  /// Asks, streams the answer into the message row, and keeps the whole
  /// exchange whether or not it succeeds.
  Future<void> ask(String threadId, String question) async {
    if (state.busy) return;

    final repository = ref.read(coachRepositoryProvider);
    final history = await repository.watchMessages(threadId).first;

    await repository.addMessage(
      threadId: threadId,
      role: 'user',
      content: question,
    );

    // The assistant's row exists before the first word arrives, so a turn that
    // dies halfway leaves a visible half-answer rather than nothing at all.
    final messageId = await repository.addMessage(
      threadId: threadId,
      role: 'assistant',
      content: '',
    );
    state = Answering(messageId: messageId, busy: true);

    final buffer = StringBuffer();
    // A stream can end without saying how it ended — the function dying
    // mid-answer looks exactly like a quiet success from here. Without this,
    // the turn leaves an empty bubble and says nothing, which is the same
    // silent discard that lost progression_state in Phase 1.
    var finished = false;

    try {
      final events = ref
          .read(coachServiceProvider)
          .ask(
            message: question,
            history: [
              for (final m in history)
                if (m.content.trim().isNotEmpty)
                  (role: m.role, text: m.content),
            ],
          );

      await for (final event in events) {
        switch (event) {
          case CoachDelta(:final text):
            buffer.write(text);
            state = state.copyWith(text: buffer.toString());

          case CoachDone(:final text, :final chips, :final model):
            finished = true;
            await repository.updateMessage(
              messageId,
              // The server's assembled text wins over the streamed pieces:
              // a dropped frame would otherwise be saved as the answer.
              content: text.isEmpty ? buffer.toString() : text,
              chips: chips,
              model: model,
              inputTokens: event.inputTokens,
              outputTokens: event.outputTokens,
              error: event.stop == 'end'
                  ? null
                  : 'Stopped early: ${event.stop}',
            );

          case CoachFailed(:final message):
            finished = true;
            await repository.updateMessage(
              messageId,
              content: buffer.toString(),
              error: message,
            );
        }
      }
    } catch (e) {
      // Nothing reaches here through the stream, which reports its own
      // failures — this is for a repository write going wrong, and even then
      // the turn has to leave a trace.
      finished = true;
      await repository.updateMessage(
        messageId,
        content: buffer.toString(),
        error: '$e',
      );
    } finally {
      // The stream ended without saying how. A function that dies mid-answer
      // looks exactly like a quiet success from here, and an empty bubble that
      // explains nothing is worse than an error that does.
      if (!finished) {
        await repository.updateMessage(
          messageId,
          content: buffer.toString(),
          error: buffer.isEmpty
              ? 'The coach stopped without answering.'
              : 'The answer was cut off.',
        );
      }
      state = const Answering();
    }
  }
}

final coachTurnProvider = NotifierProvider<CoachTurn, Answering>(CoachTurn.new);

class CoachScreen extends ConsumerWidget {
  const CoachScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thread = ref.watch(currentThreadProvider);

    return TabScaffold(
      title: 'Coach',
      actions: const [_ProposalsButton()],
      body: switch (thread) {
        AsyncData(value: final threadId) => _Conversation(threadId: threadId),
        AsyncError(:final error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text("Couldn't open the conversation.\n$error"),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// A badge on the pending-proposals count, opening the inbox.
class _ProposalsButton extends ConsumerWidget {
  const _ProposalsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingProposalsProvider).value?.length ?? 0;

    return Badge(
      label: Text('$count'),
      isLabelVisible: count > 0,
      child: IconButton(
        tooltip: 'Proposals',
        icon: const Icon(Icons.fact_check_outlined),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ProposalsScreen()),
        ),
      ),
    );
  }
}

class _Conversation extends ConsumerStatefulWidget {
  const _Conversation({required this.threadId});

  final String threadId;

  @override
  ConsumerState<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends ConsumerState<_Conversation> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final question = _input.text.trim();
    if (question.isEmpty) return;
    _input.clear();
    _toBottom();
    await ref.read(coachTurnProvider.notifier).ask(widget.threadId, question);
    _toBottom();
  }

  void _toBottom() {
    // After the frame, so the list has the new row in it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages =
        ref.watch(coachMessagesProvider(widget.threadId)).value ?? const [];
    final answering = ref.watch(coachTurnProvider);

    ref.listen(coachMessagesProvider(widget.threadId), (_, _) => _toBottom());

    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? const _Opening()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: messages.length,
                  itemBuilder: (context, i) => _Bubble(
                    message: messages[i],
                    // The row in flight renders from the streaming buffer
                    // rather than from the database.
                    streaming: messages[i].id == answering.messageId
                        ? answering.text
                        : null,
                    busy:
                        messages[i].id == answering.messageId && answering.busy,
                  ),
                ),
        ),
        _Composer(controller: _input, busy: answering.busy, onSend: _send),
      ],
    );
  }
}

/// What the coach can be asked, before there is anything to show.
class _Opening extends StatelessWidget {
  const _Opening();

  static const _examples = [
    'How has my bench been going?',
    'Am I losing weight too fast?',
    'What should I train today?',
    'Why is my squat stalled?',
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 40, color: muted),
            const SizedBox(height: 16),
            Text('A coach that has read your logs', style: text.titleMedium),
            const SizedBox(height: 8),
            Text(
              'It can see your training, food, weight and recovery. It cannot '
              'change anything on its own — everything it suggests comes to you '
              'first.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 20),
            for (final example in _examples)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '“$example”',
                  style: text.bodySmall?.copyWith(color: muted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.streaming, this.busy = false});

  final CoachMessage message;

  /// The text arriving right now, if this is the row being written.
  final String? streaming;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mine = message.role == 'user';
    final body = streaming ?? message.content;
    final chips = chipsOf(message);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (chips.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final chip in chips) _Chip(chip: chip)],
              ),
              const SizedBox(height: 8),
            ],
            if (body.isNotEmpty)
              SelectableText(body, style: theme.textTheme.bodyLarge),
            if (busy && body.isEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text('Reading your logs', style: theme.textTheme.bodySmall),
                ],
              ),
            // Never swallowed. A turn that failed says so, in place, the same
            // way a refused upload does.
            if (message.error case final failure?) ...[
              if (body.isNotEmpty) const SizedBox(height: 8),
              Text(
                failure,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What the coach looked at. docs/PLAN.md §7: "Checked 6 weeks of bench
/// sessions" — visible, so an answer can be trusted or questioned.
class _Chip extends StatelessWidget {
  const _Chip({required this.chip});

  final CoachChip chip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = chip.ok
        ? PillarColors.of(context).coach
        : theme.colorScheme.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        chip.summary.isEmpty ? chip.tool : chip.summary,
        style: theme.textTheme.labelSmall?.copyWith(color: colour),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !busy,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => busy ? null : onSend(),
                decoration: const InputDecoration(
                  hintText: 'Ask about your training',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: busy ? null : onSend,
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Ask',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ],
        ),
      ),
    );
  }
}
