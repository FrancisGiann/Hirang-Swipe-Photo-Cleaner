import 'dart:async';

import 'package:flutter/material.dart';

import '../app/sift_controller.dart';
import '../data/demo_fixtures.dart';
import '../domain/review_state.dart';
import '../platform/sift_gateway.dart';
import 'marked_review_screen.dart';
import 'photo_art.dart';
import 'photo_viewer.dart';

class PhotoToolsScreen extends StatefulWidget {
  const PhotoToolsScreen({
    super.key,
    required this.controller,
    required this.initialMode,
  });

  final SiftController controller;
  final PhotoQueryMode initialMode;

  @override
  State<PhotoToolsScreen> createState() => _PhotoToolsScreenState();
}

class _PhotoToolsScreenState extends State<PhotoToolsScreen>
    with WidgetsBindingObserver {
  late PhotoQueryMode _mode;
  final ScrollController _scrollController = ScrollController();
  List<PhotoAsset> _items = const [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = false;
  String _status = 'loading';
  String? _message;
  int? _lastKnownSizeBytes;
  int _requestRevision = 0;
  bool _openingViewer = false;
  bool _lastDemoMode = false;
  String _lastAccessStatus = '';
  int _lastCatalogRevision = 0;

  SiftController get controller => widget.controller;
  bool get _isScreenshot =>
      widget.initialMode == PhotoQueryMode.screenshotHints;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _lastDemoMode = controller.demoMode;
    _lastAccessStatus = controller.access.status;
    _lastCatalogRevision = controller.photoCatalogRevision;
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_controllerChanged);
    _scrollController.addListener(_loadNearEnd);
    unawaited(_loadPage(reset: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_controllerChanged);
    _scrollController
      ..removeListener(_loadNearEnd)
      ..dispose();
    super.dispose();
  }

  void _controllerChanged() {
    if (!mounted) return;
    final demo = controller.demoMode;
    final access = controller.access.status;
    final catalogRevision = controller.photoCatalogRevision;
    final shouldReload =
        demo != _lastDemoMode ||
        access != _lastAccessStatus ||
        catalogRevision != _lastCatalogRevision;
    if (shouldReload) {
      _lastDemoMode = demo;
      _lastAccessStatus = access;
      _lastCatalogRevision = catalogRevision;
    }
    setState(() {});
    if (shouldReload) unawaited(_loadPage(reset: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && controller.initialized) {
      PhotoArtwork.invalidateAll();
      unawaited(controller.refreshFromSystem());
    } else {
      PhotoArtwork.cancelPrefetch();
    }
  }

  void _loadNearEnd() {
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter < 360 &&
        _hasMore &&
        !_loading) {
      unawaited(_loadPage(reset: false));
    }
  }

  Future<void> _loadPage({required bool reset}) async {
    if (_loading && !reset) return;
    final revision = ++_requestRevision;
    final mode = _mode;
    final demo = controller.demoMode;
    final access = controller.access.status;
    final catalogRevision = controller.photoCatalogRevision;
    final cursor = reset ? null : _cursor;
    final trashOutcomesAtSnapshot = controller.appliedTrashOutcomesSnapshot();
    setState(() {
      _loading = true;
      if (reset) {
        _items = const [];
        _cursor = null;
        _hasMore = false;
        _message = null;
        _status = 'loading';
        _lastKnownSizeBytes = null;
      }
    });
    try {
      if (demo) {
        final samples = DemoFixtures.items.where((item) {
          if (mode == PhotoQueryMode.screenshotHints) {
            return item.screenshotHeuristic;
          }
          if (mode == PhotoQueryMode.largestKnown) {
            return item.knownSizeBytes != null;
          }
          return item.knownSizeBytes == null;
        }).toList();
        if (mode == PhotoQueryMode.largestKnown) {
          samples.sort(
            (a, b) => b.knownSizeBytes!.compareTo(a.knownSizeBytes!),
          );
        }
        if (!mounted ||
            revision != _requestRevision ||
            demo != controller.demoMode ||
            catalogRevision != controller.photoCatalogRevision) {
          return;
        }
        setState(() {
          _items = List.unmodifiable(samples);
          _status = 'ready';
          _hasMore = false;
        });
        return;
      }
      if (!controller.access.canRead) {
        if (mounted && revision == _requestRevision) {
          setState(() {
            _status = 'denied';
            _items = const [];
            _hasMore = false;
          });
        }
        return;
      }
      final gateway = controller.gateway;
      if (gateway is! PagedPhotoGateway) {
        if (mounted && revision == _requestRevision) {
          setState(() => _status = 'unsupported');
        }
        return;
      }
      final page = await (gateway as PagedPhotoGateway).queryPhotoPage(
        mode: mode,
        pageSize: 40,
        cursor: cursor,
      );
      final stillCurrent =
          mounted &&
          revision == _requestRevision &&
          mode == _mode &&
          demo == controller.demoMode &&
          access == controller.access.status &&
          catalogRevision == controller.photoCatalogRevision;
      if (!stillCurrent) return;
      if (page.status == 'stale' && cursor != null) {
        await _loadPage(reset: true);
        return;
      }
      if (page.hasMore && page.cursor == null) {
        setState(() {
          _status = 'unsupported';
          _message = 'MediaStore returned an incomplete page cursor. Refresh to try again.';
          _hasMore = false;
        });
        return;
      }
      final eligibleItems = page.items
          .where((item) => photoMatchesQueryMode(mode, item))
          .toList(growable: false);
      final mismatchedRows = eligibleItems.length != page.items.length;
      if (mode == PhotoQueryMode.largestKnown) {
        var previousSize = reset ? null : _lastKnownSizeBytes;
        for (final item in eligibleItems) {
          final size = item.knownSizeBytes!;
          if (previousSize != null && size > previousSize) {
            setState(() {
              _status = 'unsupported';
              _message = 'The provider did not return largest-first order. Refresh to try again.';
              _hasMore = false;
            });
            return;
          }
          previousSize = size;
        }
      }
      await controller.reconcileToolPage(
        items: eligibleItems,
        appliedEventsAtSnapshot: trashOutcomesAtSnapshot,
        expectedCatalogRevision: catalogRevision,
        expectedAccess: access,
      );
      if (!mounted ||
          revision != _requestRevision ||
          catalogRevision != controller.photoCatalogRevision ||
          access != controller.access.status ||
          demo != controller.demoMode) {
        return;
      }
      final accessibleItems = eligibleItems
          .where(
            (item) => !controller.state.terminalTrashedIds.contains(item.id),
          )
          .toList(growable: false);
      setState(() {
        _status = mismatchedRows || page.isPartial ? 'partial' : page.status;
        _message = mismatchedRows
            ? 'Some returned rows did not match this tool’s photo filter. They were skipped; refresh to verify the results.'
            : page.message;
        if (page.isSupported) {
          final seen = reset
              ? <String>{}
              : _items.map((item) => item.id).toSet();
          _items = List.unmodifiable([
            if (!reset) ..._items,
            ...accessibleItems.where((item) => seen.add(item.id)),
          ]);
          _cursor = page.cursor;
          _hasMore = page.hasMore;
          _lastKnownSizeBytes =
              mode == PhotoQueryMode.largestKnown && eligibleItems.isNotEmpty
              ? eligibleItems.last.knownSizeBytes
              : mode == PhotoQueryMode.largestKnown && !reset
              ? _lastKnownSizeBytes
              : null;
        } else {
          _hasMore = false;
        }
      });
    } catch (_) {
      if (mounted && revision == _requestRevision) {
        setState(() {
          _status = 'error';
          _message = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
          _hasMore = false;
        });
      }
    } finally {
      if (mounted && revision == _requestRevision) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refresh() async {
    PhotoArtwork.invalidateAll();
    await controller.refreshFromSystem();
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibleItems = _items
        .where((item) => !controller.state.terminalTrashedIds.contains(item.id))
        .toList(growable: false);
    final title = _isScreenshot ? 'Screenshots cleanup' : 'Large photos';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Refresh photo results',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Marked photos, ${controller.marked.length} selected',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MarkedReviewScreen(controller: controller),
              ),
            ),
            icon: Badge(
              isLabelVisible: controller.marked.isNotEmpty,
              label: Text('${controller.marked.length}'),
              child: const Icon(Icons.bookmark_outline_rounded),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_isScreenshot)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
                      child: SegmentedButton<PhotoQueryMode>(
                        segments: const [
                          ButtonSegment(
                            value: PhotoQueryMode.largestKnown,
                            label: Text('Largest'),
                            icon: Icon(Icons.storage_rounded),
                          ),
                          ButtonSegment(
                            value: PhotoQueryMode.unknownSize,
                            label: Text('Size unknown'),
                            icon: Icon(Icons.help_outline_rounded),
                          ),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (selection) {
                          setState(() => _mode = selection.first);
                          unawaited(_loadPage(reset: true));
                        },
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _isScreenshot
                              ? 'Folder and album names are hints. Photos without a screenshot hint stay out of this list.'
                              : 'Photos only. Videos and unsupported media are not included.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        if (_mode == PhotoQueryMode.largestKnown) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Sorted by known positive photo size. Marked photos go through Android’s existing trash confirmation; selected size does not mean storage has been freed.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (_mode == PhotoQueryMode.unknownSize) ...[
                          const SizedBox(height: 4),
                          Text(
                            'These photos have no positive size value. They are separate from the largest-first list and do not contribute to a size estimate.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (controller.demoMode)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Fictional sample photos and sizes',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.tertiary,
                              ),
                            ),
                          ),
                        if (!controller.demoMode && controller.access.isLimited)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Showing only photos included in selected-photo access. Other library photos may not appear.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (!controller.demoMode &&
                            controller.access.status == 'full')
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Showing photos currently accessible to Hirang.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (controller.error != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                            child: Text(
                              controller.error!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        if (_status == 'partial')
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _message ?? 'This page is incomplete. Refresh photo access to check again.',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_status == 'denied')
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Photo access is off. These tools use the photos you choose to share with Hirang.',
                          ),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: controller.loading
                                ? null
                                : controller.connectLibrary,
                            child: const Text('Choose photo access'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_status == 'unsupported' || _status == 'error')
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    _message ?? 'Could not load this photo list safely. Refresh to retry; saved decisions remain.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ),
            if (visibleItems.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : _emptyState(theme),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 18),
                sliver: SliverList.builder(
                  itemCount: visibleItems.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == visibleItems.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: _loading
                              ? const CircularProgressIndicator()
                              : TextButton.icon(
                                  onPressed: () => _loadPage(reset: false),
                                  icon: const Icon(Icons.expand_more_rounded),
                                  label: const Text('Load more photos'),
                                ),
                        ),
                      );
                    }
                    final item = visibleItems[index];
                    return _ToolPhotoRow(
                      item: item,
                      controller: controller,
                      screenshotMode: _isScreenshot,
                      onOpen: () => _openPhoto(item),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    String message;
    if (_status == 'denied') {
      message = 'Choose photo access to use this tool.';
    } else if (_status == 'unsupported') {
      message = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
    } else if (_hasMore) {
      message = 'No eligible photos were returned in this page. More accessible pages remain.';
    } else if (_isScreenshot) {
      message = 'No identified screenshot folder or album hints were found in the accessible photos. Other photos are not included.';
    } else if (_mode == PhotoQueryMode.unknownSize) {
      message =
          'No photos with an unknown size value were returned in this page.';
    } else {
      message =
          'No photos with a known positive size were returned in this page.';
    }
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 54,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          if (_hasMore)
            TextButton.icon(
              onPressed: _loading ? null : () => _loadPage(reset: false),
              icon: const Icon(Icons.expand_more_rounded),
              label: const Text('Check the next photo page'),
            ),
        ],
      ),
    );
  }
}

class _ToolPhotoRow extends StatelessWidget {
  const _ToolPhotoRow({
    required this.item,
    required this.controller,
    required this.screenshotMode,
    required this.onOpen,
  });

  final PhotoAsset item;
  final SiftController controller;
  final bool screenshotMode;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final decision = controller.state.decisions[item.id];
    final locked = controller.state.operation?.locks(item.id) ?? false;
    final evidence =
        (item.relativePath?.toLowerCase().contains('screenshot') ?? false)
        ? 'Folder hint: ${item.relativePath}'
        : item.album != null
        ? 'Album hint: ${item.album}'
        : 'Folder or album hint';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                Semantics(
                  button: true,
                  label: 'Open ${item.title}',
                  hint: 'View full-screen and zoom',
                  child: InkWell(
                    onTap: onOpen,
                    child: SizedBox(
                      width: 76,
                      height: 76,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: PhotoArtwork(
                          item: item,
                          demoMode: controller.demoMode,
                          gateway: controller.gateway,
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
                      const SizedBox(height: 3),
                      Text(
                        screenshotMode
                            ? 'Possible screenshot · $evidence'
                            : _sizeLabel(item.knownSizeBytes),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (!screenshotMode && item.album != null)
                        Text(
                          item.album!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (decision != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            decision == ReviewDecision.keep ? 'Kept' : 'Marked',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (decision == null)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: locked
                          ? null
                          : () => controller.decideVerified(
                              item,
                              ReviewDecision.keep,
                            ),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Keep'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: locked
                          ? null
                          : () => controller.decideVerified(
                              item,
                              ReviewDecision.mark,
                            ),
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: const Text('Mark'),
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  if (decision == ReviewDecision.mark)
                    TextButton.icon(
                      onPressed: locked
                          ? null
                          : () => controller.unmark(item.id),
                      icon: const Icon(Icons.bookmark_remove_outlined),
                      label: const Text('Unmark'),
                    )
                  else if (controller.state.undoableId == item.id)
                    TextButton.icon(
                      onPressed: controller.undo,
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Undo keep'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            MarkedReviewScreen(controller: controller),
                      ),
                    ),
                    child: const Text('Marked Photos'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

String _sizeLabel(int? bytes) {
  if (bytes == null || bytes <= 0) return 'Size unknown';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value < 10 ? value.toStringAsFixed(1) : value.toStringAsFixed(0)} ${units[unit]}';
}
