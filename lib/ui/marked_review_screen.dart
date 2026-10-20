import 'package:flutter/material.dart';

import '../app/brand.dart';
import '../app/sift_controller.dart';
import '../domain/review_state.dart';
import 'operation_panel.dart';
import 'photo_art.dart';
import 'photo_viewer.dart';

class MarkedReviewScreen extends StatefulWidget {
  const MarkedReviewScreen({super.key, required this.controller});

  final SiftController controller;

  @override
  State<MarkedReviewScreen> createState() => _MarkedReviewScreenState();
}

class _MarkedReviewScreenState extends State<MarkedReviewScreen> {
  bool _checking = false;
  bool _photoViewerOpen = false;
  SiftController get controller => widget.controller;

  Future<void> _openPhoto(PhotoAsset item) async {
    if (_photoViewerOpen || !mounted) return;
    _photoViewerOpen = true;
    try {
      await showPhotoFullscreen(
        context,
        item: item,
        demoMode: controller.demoMode,
        gateway: controller.gateway,
      );
    } finally {
      if (mounted) _photoViewerOpen = false;
    }
  }

  @override
  void initState() {
    super.initState();
    controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final marked = controller.marked;
    final knownBytes = marked
        .where((item) => item.knownSizeBytes != null)
        .fold<int>(0, (sum, item) => sum + item.knownSizeBytes!);
    final unknownSizes = marked
        .where((item) => item.knownSizeBytes == null)
        .length;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Marked photos'),
          leading: IconButton(
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back',
          ),
          actions: [
            if (marked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    '${marked.length} selected',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OperationPanel(controller: controller),
                    if (controller.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          controller.error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    if (controller.demoMode)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Text(
                          'Demo marks are fictional examples. They cannot be sent to Android or affect your library.',
                        ),
                      )
                    else
                      Text(
                        '${_sizeLabel(knownBytes)} estimated selected size${unknownSizes == 0 ? '' : ' · $unknownSizes size unknown'}. System trash may continue to use storage.',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: marked.isEmpty
                    ? _EmptyMarks(demoMode: controller.demoMode)
                    : GridView.builder(
                        key: const Key('markedGrid'),
                        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 240,
                              mainAxisExtent: 224,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                        itemCount: marked.length,
                        itemBuilder: (context, index) {
                          final item = marked[index];
                          final locked =
                              controller.state.operation?.locks(item.id) ??
                              false;
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            margin: EdgeInsets.zero,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Semantics(
                                        button: true,
                                        label: 'Open ${item.title}',
                                        hint: 'View full-screen and zoom',
                                        child: InkWell(
                                          key: Key(
                                            'openMarkedPhoto-${item.id}',
                                          ),
                                          onTap: () => _openPhoto(item),
                                          child: PhotoArtwork(
                                            item: item,
                                            demoMode: controller.demoMode,
                                            gateway: controller.gateway,
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        top: 6,
                                        right: 6,
                                        child: IconButton.filledTonal(
                                          key: Key('unmark-${item.id}'),
                                          onPressed: locked || _checking
                                              ? null
                                              : () =>
                                                    controller.unmark(item.id),
                                          tooltip: locked
                                              ? 'Frozen during Android review'
                                              : _checking
                                              ? 'Photo selection is being checked'
                                              : 'Unmark ${item.title}',
                                          icon: Icon(
                                            locked
                                                ? Icons.lock_outline_rounded
                                                : Icons
                                                      .bookmark_remove_outlined,
                                            size: 18,
                                          ),
                                          style: IconButton.styleFrom(
                                            minimumSize: const Size(42, 42),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    9,
                                    12,
                                    10,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${item.album ?? 'Album unknown'} · ${item.knownSizeBytes == null ? 'Size unknown' : _sizeLabel(item.knownSizeBytes!)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              if (marked.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('trashMarkedButton'),
                      onPressed:
                          _checking ||
                              controller.demoMode ||
                              !controller.access.canRead ||
                              controller.state.operation?.isActive == true
                          ? null
                          : _confirmTrash,
                      icon: _checking
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_outline_rounded),
                      label: Text(
                        controller.demoMode
                            ? 'Trash unavailable in demo'
                            : !controller.access.canRead
                            ? 'Photo access needed'
                            : controller.state.operation?.isActive == true
                            ? 'Android review in progress'
                            : 'Move to system trash',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 54),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmTrash() async {
    if (_checking) return;
    final List<PhotoAsset> selectedPhotos = List<PhotoAsset>.unmodifiable(
      controller.marked,
    );
    if (selectedPhotos.isEmpty) return;
    final expectedIds = selectedPhotos.map((item) => item.id).toList();
    setState(() => _checking = true);
    try {
      final validation = await controller.revalidateMarked(
        selection: selectedPhotos,
      );
      if (!mounted) return;
      final present = validation.values
          .where((item) => item.status == 'present')
          .length;
      final trashed = validation.values
          .where((item) => item.status == 'trashed')
          .length;
      final unknown = selectedPhotos.length - present - trashed;
      final canSubmit = present > 0;
      String photoCount(int count) => '$count photo${count == 1 ? '' : 's'}';
      final checkSummary =
          '${photoCount(present)} ${present == 1 ? 'is' : 'are'} available, '
          '${photoCount(trashed)} ${trashed == 1 ? 'already appears' : 'already appear'} in system trash, and '
          '${photoCount(unknown)} could not be checked.';
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.delete_outline_rounded),
          title: const Text('Review before system trash'),
          content: Text(
            '${selectedPhotos.length} marked photo${selectedPhotos.length == 1 ? '' : 's'} ${selectedPhotos.length == 1 ? 'is' : 'are'} selected. Last check: $checkSummary Only available photos will be sent to Android.\n\nNext, review the system confirmation. Photos are not moved to trash until you approve it.\n\n$appDisplayName requests recoverable system trash. Android may later expire trashed items; recovery is through your gallery’s supported trash view.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Go back'),
            ),
            FilledButton(
              onPressed: canSubmit ? () => Navigator.pop(context, true) : null,
              child: const Text(
                'Review system confirmation',
                key: Key('reviewSystemConfirmationButton'),
                maxLines: 2,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
      if (accepted == true) {
        await controller.beginTrash(expectedItemIds: expectedIds);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Could not check the selected photos. Please retry.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }
}

class _EmptyMarks extends StatelessWidget {
  const _EmptyMarks({required this.demoMode});
  final bool demoMode;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bookmark_border_rounded,
            size: 46,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            demoMode ? 'No sample marks yet' : 'Nothing marked',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text(
            'Left swipes stay local. Mark a photo when you want to consider it later.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

String _sizeLabel(int bytes) => bytes < 1 << 20
    ? '${(bytes / 1024).round()} KB'
    : '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
