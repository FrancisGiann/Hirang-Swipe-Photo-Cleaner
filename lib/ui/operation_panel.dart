import 'package:flutter/material.dart';

import '../app/brand.dart';
import '../app/sift_controller.dart';
import '../domain/review_state.dart';

class OperationPanel extends StatelessWidget {
  const OperationPanel({super.key, required this.controller});

  final SiftController controller;

  @override
  Widget build(BuildContext context) {
    final operation = controller.state.operation;
    if (operation == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final awaiting = operation.status == 'awaitingSystemApproval';
    final needsContinue = operation.status == 'needsContinue';
    final terminal = !operation.isActive;
    final color = awaiting || needsContinue
        ? theme.colorScheme.tertiaryContainer
        : terminal
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.secondaryContainer;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  awaiting ? Icons.open_in_new_rounded : Icons.shield_outlined,
                  size: 20,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    _headline(operation),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${operation.verifiedTrashedCount}/${operation.items.length}',
                  style: theme.textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_detail(operation), style: theme.textTheme.bodySmall),
            if (operation.unresolvedCount > 0 && terminal) ...[
              const SizedBox(height: 6),
              Text(
                '${operation.unresolvedCount} photo${operation.unresolvedCount == 1 ? '' : 's'} still ${operation.unresolvedCount == 1 ? 'needs' : 'need'} attention. They were not counted as trashed.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (awaiting || needsContinue || terminal) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _act(context, operation),
                  icon: Icon(
                    awaiting
                        ? Icons.refresh_rounded
                        : needsContinue
                        ? Icons.arrow_forward_rounded
                        : Icons.close_rounded,
                  ),
                  label: Text(
                    awaiting
                        ? 'I’m back — recheck'
                        : needsContinue
                        ? 'Review next batch'
                        : 'Close result',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _headline(TrashOperation operation) => switch (operation.status) {
    'prepared' => 'Getting your selection ready',
    'awaitingSystemApproval' => 'Android trash review is pending',
    'resultReceived' => 'Checking Android’s response',
    'needsContinue' => 'One batch finished',
    'complete' => 'Trash request finished',
    'cancelled' => 'Trash request cancelled',
    'interrupted' => 'Trash request interrupted',
    'failed' => 'Trash request could not start',
    _ => 'Trash request status is uncertain',
  };

  String _detail(TrashOperation operation) => switch (operation.status) {
    'awaitingSystemApproval' =>
      'Selected photos stay locked while Android’s confirmation is open. $appDisplayName checks each one after you return.',
    'needsContinue' =>
      'The next group has not been sent. $appDisplayName will check the selected photos again and ask you to confirm.',
    'complete' =>
      '${operation.verifiedTrashedCount} photo${operation.verifiedTrashedCount == 1 ? '' : 's'} ${operation.verifiedTrashedCount == 1 ? 'was' : 'were'} verified in system trash. Trash may continue to use storage.',
    'cancelled' => 'Android cancelled this request. Confirmed changes stay recorded; photos that could not be checked stay available.',
    'interrupted' =>
      '$appDisplayName could not confirm every selected photo after Android returned. Unresolved photos stay available for review.',
    'resultReceived' =>
      'Android returned. $appDisplayName is checking what happened to the selected photos.',
    _ =>
      'The selected photos stay in this on-device result until you close it.',
  };

  Future<void> _act(BuildContext context, TrashOperation operation) async {
    if (operation.status == 'awaitingSystemApproval') {
      final returned = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Back from Android’s screen?'),
          content: const Text(
            'Continue only after you have closed Android’s trash prompt and returned to $appDisplayName. Photos stay locked while it is open.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not yet'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Recheck now'),
            ),
          ],
        ),
      );
      if (returned == true) {
        await controller.refreshOperation(afterSystemScreenClosed: true);
      }
    } else if (operation.status == 'needsContinue') {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Continue with the next group?'),
          content: const Text(
            '$appDisplayName will check the remaining selected photos again. Android will ask you to confirm another group. Nothing retries in the background.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Review later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (proceed == true) await controller.continueTrash();
    } else if (!operation.isActive) {
      await controller.clearFinishedOperation();
    }
  }
}
