import 'package:flutter/material.dart';

import '../app/sift_controller.dart';
import '../domain/review_state.dart';
import '../platform/sift_gateway.dart';
import 'marked_review_screen.dart';
import 'photo_art.dart';
import 'photo_viewer.dart';

class CleanupSessionsScreen extends StatefulWidget {
  const CleanupSessionsScreen({super.key, required this.controller});

  final SiftController controller;

  @override
  State<CleanupSessionsScreen> createState() => _CleanupSessionsScreenState();
}

class _CleanupSessionsScreenState extends State<CleanupSessionsScreen> {
  CleanupSessionKind _kind = CleanupSessionKind.photos;
  DateTime? _selectedMonth;
  bool _openingViewer = false;

  SiftController get controller => widget.controller;

  String? get _monthKey {
    final month = _selectedMonth;
    if (month == null) return null;
    return '${month.year}-${month.month.toString().padLeft(2, '0')}';
  }

  String get _cursorScope =>
      '${_kind == CleanupSessionKind.screenshots ? PhotoQueryMode.screenshotHints.name : PhotoQueryMode.recent.name}|$_monthKey|${controller.demoMode}';

  Future<void> _chooseMonth() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _selectedMonth ?? now,
      firstDate: DateTime(1970),
      lastDate: now,
      helpText: 'Choose a date group',
    );
    if (selected != null && mounted) {
      setState(() => _selectedMonth = selected);
    }
  }

  Future<void> _openPhoto(PhotoAsset item) async {
    if (_openingViewer || !mounted) return;
    _openingViewer = true;
    try {
      await showPhotoFullscreen(
        context,
        item: item,
        demoMode: controller.demoMode,
        gateway: controller.gateway,
      );
    } finally {
      if (mounted) _openingViewer = false;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final session = controller.state.cleanupSession;
      final active = session?.isActive == true;
      final theme = Theme.of(context);
      if (active && session!.demoMode != controller.demoMode) {
        return Scaffold(
          appBar: AppBar(title: const Text('Cleanup sessions')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This saved batch belongs to a different photo deck.',
              ),
            ),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: const Text('Cleanup sessions'),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MarkedReviewScreen(controller: controller),
                ),
              ),
              icon: const Icon(Icons.bookmark_outline_rounded),
              label: Text('Marked ${controller.marked.length}'),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            children: [
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    controller.error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              if (!active) ...[
                Text(
                  'Review a small, saved batch at your pace.',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Each session saves a batch of up to 20 photos. Keep and Mark decisions stay in your regular review and Marked Photos. Photos hidden by access limits are not counted as reviewed.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<CleanupSessionKind>(
                  key: const Key('cleanupKind'),
                  initialValue: _kind,
                  decoration: const InputDecoration(
                    labelText: 'Photo group',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: CleanupSessionKind.photos,
                      child: Text('Photos by date'),
                    ),
                    DropdownMenuItem(
                      value: CleanupSessionKind.screenshots,
                      child: Text('Screenshot folder hints'),
                    ),
                  ],
                  onChanged: (value) => setState(
                    () => _kind = value ?? CleanupSessionKind.photos,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _chooseMonth,
                  icon: const Icon(Icons.calendar_month_rounded),
                  label: Text(
                    _selectedMonth == null
                        ? 'Any date'
                        : _monthLabel(_selectedMonth!),
                  ),
                ),
                const SizedBox(height: 8),
                if (_kind == CleanupSessionKind.screenshots)
                  const Text(
                    'Only photos whose album or folder path contains a screenshot hint are included. No other photos are added when no hint is found.',
                  ),
                if (!controller.demoMode && !controller.access.canRead) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Photo access is off. Choose photo access from the main screen to start a library session.',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 18),
                if (controller.state.cleanupPageCursor != null &&
                    controller.state.cleanupCursorScope == _cursorScope)
                  FilledButton.icon(
                    key: const Key('continueCleanupPage'),
                    onPressed: () => controller.startCleanupSession(
                      kind: _kind,
                      monthKey: _monthKey,
                    ),
                    icon: const Icon(Icons.navigate_next_rounded),
                    label: const Text('Continue to next photo page'),
                  )
                else
                  FilledButton.icon(
                    key: const Key('startCleanupSession'),
                    onPressed: () => controller.startCleanupSession(
                      kind: _kind,
                      monthKey: _monthKey,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Start 20-photo session'),
                  ),
                if (session?.status == CleanupSessionStatus.finished) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Last batch: ${session!.items.where((item) => controller.state.decisions.containsKey(item.id)).length} reviewed of ${session.items.length}. Decisions remain saved.',
                  ),
                ],
              ] else ...[
                _ActiveSessionSummary(
                  session: session!,
                  decisions: controller.state.decisions,
                  accessAvailable:
                      controller.demoMode || controller.access.canRead,
                  onResume: controller.resumeCleanupSession,
                  onFinish: controller.finishCleanupSession,
                ),
                const SizedBox(height: 14),
                for (final item in session.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SessionPhotoRow(
                      item: item,
                      session: session,
                      controller: controller,
                      onOpen: () => _openPhoto(item),
                    ),
                  ),
              ],
              if (controller.hasMorePhotos && !controller.demoMode) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: controller.loadingMorePhotos
                      ? null
                      : controller.loadMorePhotos,
                  icon: controller.loadingMorePhotos
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.expand_more_rounded),
                  label: const Text('Load another accessible photo page'),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _ActiveSessionSummary extends StatelessWidget {
  const _ActiveSessionSummary({
    required this.session,
    required this.decisions,
    required this.accessAvailable,
    required this.onResume,
    required this.onFinish,
  });

  final CleanupSession session;
  final Map<String, ReviewDecision> decisions;
  final bool accessAvailable;
  final VoidCallback onResume;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final reviewed = session.items
        .where((item) => decisions.containsKey(item.id))
        .length;
    final pending = session.items.length - reviewed;
    final unconfirmed = session.items
        .where(
          (item) =>
              session.availability[item.id] == CleanupAvailability.unconfirmed,
        )
        .length;
    final progress = session.items.isEmpty
        ? 0.0
        : reviewed / session.items.length;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              session.kind == CleanupSessionKind.screenshots
                  ? 'Screenshot hint session'
                  : 'Photo session${session.monthKey == null ? '' : ' · ${_monthKeyLabel(session.monthKey!)}'}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$reviewed of ${session.items.length} photos have saved decisions.',
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            if (!accessAvailable)
              const Text(
                'Photo access is off. Pending identities are not counted as reviewed.',
              ),
            if (session.sourcePagePartial)
              const Text(
                'The source page was incomplete. Finishing this batch does not establish that unseen photos are reviewed; refresh access before continuing.',
              ),
            if (unconfirmed > 0)
              Text(
                '$unconfirmed snapshot ${unconfirmed == 1 ? 'item is' : 'items are'} not currently confirmed as accessible. They remain pending unless a decision was already saved.',
              ),
            if (pending == 0)
              const Text(
                'Every photo in this batch has a saved decision. Finish to close this session.',
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: accessAvailable ? onResume : null,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Resume and check access'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('finishCleanupSession'),
                  onPressed: onFinish,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(
                    pending == 0
                        ? 'Finish session'
                        : 'Finish with $pending pending',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionPhotoRow extends StatelessWidget {
  const _SessionPhotoRow({
    required this.item,
    required this.session,
    required this.controller,
    required this.onOpen,
  });

  final PhotoAsset item;
  final CleanupSession session;
  final SiftController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final decision = controller.state.decisions[item.id];
    final available =
        controller.demoMode ||
        (controller.access.canRead &&
            controller.cleanupItemConfirmed(item.id) &&
            session.availability[item.id] == CleanupAvailability.available);
    final locked = controller.state.operation?.locks(item.id) ?? false;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Semantics(
              button: true,
              label: 'Open ${item.title}',
              hint: 'View full-screen and zoom',
              child: InkWell(
                onTap: available ? onOpen : null,
                child: SizedBox(
                  width: 68,
                  height: 68,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: available
                        ? PhotoArtwork(
                            item: item,
                            demoMode: controller.demoMode,
                            gateway: controller.gateway,
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                            ),
                            child: const Icon(
                              Icons.image_not_supported_outlined,
                            ),
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    decision == ReviewDecision.keep
                        ? 'Kept'
                        : decision == ReviewDecision.mark
                        ? 'Marked'
                        : !available
                        ? 'Not currently confirmed as accessible'
                        : 'Waiting for your decision',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (decision == null)
              PopupMenuButton<ReviewDecision>(
                tooltip: available
                    ? 'Choose keep or mark'
                    : 'Photo unavailable',
                enabled: available && !locked,
                onSelected: (value) => controller.decideVerified(item, value),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: ReviewDecision.keep,
                    child: Text('Keep'),
                  ),
                  PopupMenuItem(
                    value: ReviewDecision.mark,
                    child: Text('Mark for review'),
                  ),
                ],
                icon: const Icon(Icons.more_vert_rounded),
              )
            else if (decision == ReviewDecision.mark)
              IconButton(
                tooltip: locked
                    ? 'Frozen during system review'
                    : 'Unmark photo',
                onPressed: locked ? null : () => controller.unmark(item.id),
                icon: const Icon(Icons.bookmark_remove_outlined),
              )
            else if (controller.state.undoableId == item.id)
              IconButton(
                tooltip: 'Undo keep',
                onPressed: controller.undo,
                icon: const Icon(Icons.undo_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

String _monthLabel(DateTime date) => '${_monthName(date.month)} ${date.year}';

String _monthKeyLabel(String key) {
  final parts = key.split('-');
  if (parts.length != 2) return key;
  final month = int.tryParse(parts[1]);
  if (month == null || month < 1 || month > 12) return key;
  return '${_monthName(month)} ${parts[0]}';
}

String _monthName(int month) => const [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
][month - 1];
