import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../app/brand.dart';
import '../app/hirang_theme.dart';
import '../app/sift_controller.dart';
import '../domain/review_state.dart';
import '../platform/sift_gateway.dart';
import 'appearance_settings_screen.dart';
import 'brand_mark.dart';
import 'marked_review_screen.dart';
import 'onboarding_screen.dart';
import 'operation_panel.dart';
import 'photo_art.dart';

const double swipeDecisionThreshold = 88.0;
final RouteObserver<ModalRoute<dynamic>> photoRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

int _imageTargetEdge(Size viewport, double devicePixelRatio) {
  if (!viewport.width.isFinite || !viewport.height.isFinite) return 512;
  final physicalEdge =
      math.max(viewport.width, viewport.height) * devicePixelRatio;
  // A small bucket avoids cache churn from subpixel layout changes during a resize.
  return (((physicalEdge / 64).ceil()) * 64).clamp(512, 2048).toInt();
}

double _swipeIntentProgress(double offset) =>
    (offset.abs() / swipeDecisionThreshold).clamp(0.0, 1.0);

class SiftHome extends StatefulWidget {
  const SiftHome({super.key, required this.controller});

  final SiftController controller;

  @override
  State<SiftHome> createState() => _SiftHomeState();
}

class _SiftHomeState extends State<SiftHome>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  late final AnimationController _spring;
  late final ValueNotifier<Offset> _cardOffset;
  Offset _liveOffset = Offset.zero;
  Offset _springFrom = Offset.zero;
  Offset _springTo = Offset.zero;
  bool _springing = false;
  bool _decisionReserved = false;
  bool _decisionSaving = false;
  bool _rawPointerCancelled = false;
  int _motionEpoch = 0;
  ModalRoute<dynamic>? _route;
  bool _routeCovered = false;

  SiftController get controller => widget.controller;

  Offset get _visibleOffset => _springing
      ? Offset.lerp(_springFrom, _springTo, _spring.value) ?? _springTo
      : _liveOffset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_changed);
    _cardOffset = ValueNotifier<Offset>(Offset.zero);
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(_springChanged);
    if (!controller.initialized) unawaited(controller.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    photoRouteObserver.unsubscribe(this);
    controller.removeListener(_changed);
    _spring.removeListener(_springChanged);
    _spring.dispose();
    _cardOffset.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && !identical(route, _route)) {
      photoRouteObserver.unsubscribe(this);
      _route = route;
      photoRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _routeCovered = true;
    PhotoArtwork.cancelPrefetch();
  }

  @override
  void didPopNext() {
    _routeCovered = false;
    if (mounted) setState(() {});
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

  void _changed() {
    if (mounted) setState(() {});
  }

  void _springChanged() {
    if (mounted) _cardOffset.value = _visibleOffset;
  }

  @override
  Widget build(BuildContext context) {
    if (!controller.initialized) {
      return Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              BrandMark(size: 30),
              SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Hirang',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (!controller.startupReady) {
      return _SavedStateLoadFailure(
        loading: controller.loading,
        onRetry: controller.loading
            ? null
            : () => unawaited(controller.initialize()),
      );
    }
    if (!controller.state.onboardingComplete) {
      return OnboardingScreen(controller: controller);
    }

    final theme = Theme.of(context);
    final narrow =
        MediaQuery.sizeOf(context).width < 380 ||
        MediaQuery.textScalerOf(context).scale(16) > 20;
    final list = controller.state.filteredAssets(controller.visibleAssets);
    final current = controller.current;
    if (!controller.demoMode && current == null) {
      PhotoArtwork.cancelPrefetch();
    }
    final upcoming = !controller.demoMode && current != null
        ? (() {
            final currentIndex = list.indexWhere(
              (item) => item.id == current.id,
            );
            return currentIndex < 0
                ? const <PhotoAsset>[]
                : list
                      .skip(currentIndex + 1)
                      .where(
                        (item) =>
                            !controller.state.decisions.containsKey(item.id) &&
                            !(controller.state.operation?.locks(item.id) ??
                                false),
                      )
                      .take(3)
                      .toList(growable: false);
          })()
        : const <PhotoAsset>[];
    final total = list.length;
    final reviewed = controller.state.reviewedCount(controller.visibleAssets);
    final markedCount = controller.marked.length;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const BrandMark(size: 31),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                appDisplayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (narrow)
            IconButton(
              key: const Key('markedReviewButton'),
              tooltip: 'Marked photos, $markedCount selected',
              onPressed: _openMarked,
              icon: Badge(
                isLabelVisible: markedCount > 0,
                label: Text('$markedCount'),
                child: const Icon(Icons.bookmark_outline_rounded),
              ),
            )
          else
            TextButton.icon(
              key: const Key('markedReviewButton'),
              onPressed: _openMarked,
              icon: Badge(
                isLabelVisible: markedCount > 0,
                label: Text('$markedCount'),
                child: const Icon(Icons.bookmark_outline_rounded),
              ),
              label: Text('Marked $markedCount'),
            ),
          PopupMenuButton<_HomeAction>(
            key: const Key('photoOptionsButton'),
            tooltip: 'Photo options and help',
            onSelected: (action) {
              switch (action) {
                case _HomeAction.manageAccess:
                  unawaited(controller.connectLibrary());
                  break;
                case _HomeAction.refresh:
                  PhotoArtwork.invalidateAll();
                  unawaited(controller.refreshFromSystem());
                  break;
                case _HomeAction.settings:
                  unawaited(controller.openAppSettings());
                  break;
                case _HomeAction.appearance:
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          AppearanceSettingsScreen(controller: controller),
                    ),
                  );
                  break;
                case _HomeAction.howItWorks:
                  unawaited(_showHowItWorks(context));
                  break;
                case _HomeAction.replayIntro:
                  unawaited(_replayIntroduction(context));
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _HomeAction.manageAccess,
                child: Text(
                  controller.access.isLimited
                      ? 'Choose more photos'
                      : controller.access.canRead
                      ? 'Change photo access'
                      : 'Choose photo access',
                ),
              ),
              const PopupMenuItem(
                value: _HomeAction.refresh,
                child: Text('Refresh library'),
              ),
              const PopupMenuItem(
                key: Key('internalSettingsMenuItem'),
                value: _HomeAction.appearance,
                child: Text('Settings'),
              ),
              const PopupMenuItem(
                value: _HomeAction.settings,
                child: Text('Android app settings'),
              ),
              const PopupMenuItem(
                value: _HomeAction.howItWorks,
                child: Text('How Hirang works'),
              ),
              const PopupMenuItem(
                key: Key('replayIntroductionMenuItem'),
                value: _HomeAction.replayIntro,
                child: Text('Replay introduction'),
              ),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SessionHeader(
                          controller: controller,
                          reviewed: reviewed,
                          total: total,
                        ),
                        const SizedBox(height: 12),
                        if (!controller.demoMode &&
                            controller.access.isLimited) ...[
                          _LimitedAccessNotice(
                            onManage: controller.loading
                                ? null
                                : () => unawaited(controller.connectLibrary()),
                          ),
                          const SizedBox(height: 10),
                        ],
                        _FilterBar(controller: controller),
                        if (controller.state.operation != null) ...[
                          const SizedBox(height: 10),
                          OperationPanel(controller: controller),
                        ],
                        if (controller.error != null && current != null)
                          _ErrorNotice(
                            message: controller.error!,
                            onRetry: () =>
                                unawaited(controller.refreshFromSystem()),
                          ),
                        if (!controller.demoMode && !controller.access.canRead)
                          _AccessCard(
                            controller: controller,
                            undoEnabled: controller.state.canUndo,
                            onUndo: controller.undo,
                          )
                        else if (current == null && controller.error != null)
                          _LibraryRetryCard(
                            onRetry: () =>
                                unawaited(controller.refreshFromSystem()),
                          )
                        else if (current == null)
                          _CaughtUpCard(
                            demoMode: controller.demoMode,
                            total: total,
                            hasAssets: controller.visibleAssets.isNotEmpty,
                            hasMarked: controller.marked.isNotEmpty,
                            hasFilters:
                                controller.state.filters.monthKey != null ||
                                controller.state.filters.album != null ||
                                controller.state.filters.screenshotsOnly,
                            undoEnabled: controller.state.canUndo,
                            onUndo: controller.undo,
                            onOpenMarked: _openMarked,
                            onResetFilters: () =>
                                controller.setFilters(const ReviewFilters()),
                            onRefresh: () =>
                                unawaited(controller.refreshFromSystem()),
                          )
                        else ...[
                          const SizedBox(height: 12),
                          Expanded(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 220),
                              child: ValueListenableBuilder<Offset>(
                                valueListenable: _cardOffset,
                                child: _SwipeCard(
                                  key: ValueKey(current.id),
                                  item: current,
                                  demoMode: controller.demoMode,
                                  gateway: controller.gateway,
                                  upcoming: upcoming,
                                  allowPrefetch: !_routeCovered,
                                  offsetListenable: _cardOffset,
                                  onPanStart: _onPanStart,
                                  onPanUpdate: _onPanUpdate,
                                  onPanEnd: _onPanEnd,
                                  onPanCancel: _onPanCancel,
                                  onPointerCancel: _onRawPointerCancel,
                                ),
                                builder: (context, offset, child) =>
                                    Transform.translate(
                                      offset: offset,
                                      child: Transform.rotate(
                                        angle:
                                            (offset.dx /
                                                    MediaQuery.sizeOf(context)
                                                        .width *
                                                    .14)
                                                .clamp(-.14, .14),
                                        child: RepaintBoundary(child: child),
                                      ),
                                    ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 7),
                          _PhotoSummary(
                            item: current,
                            demoMode: controller.demoMode,
                            gateway: controller.gateway,
                          ),
                          const SizedBox(height: 7),
                          _DecisionControls(
                            undoEnabled:
                                controller.state.canUndo &&
                                !_decisionReserved &&
                                !_decisionSaving,
                            committing: _decisionReserved || _decisionSaving,
                            onMark: () => unawaited(
                              _decide(ReviewDecision.mark, current),
                            ),
                            onKeep: () => unawaited(
                              _decide(ReviewDecision.keep, current),
                            ),
                            onUndo: controller.undo,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Swipe left to mark · right to keep',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openMarked() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MarkedReviewScreen(controller: controller),
      ),
    );
  }

  Future<void> _replayIntroduction(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OnboardingScreen(controller: controller, replay: true),
      ),
    );
  }

  void _onPanStart(DragStartDetails details) {
    if (_decisionSaving) return;
    _rawPointerCancelled = false;
    final current = _visibleOffset;
    _motionEpoch++;
    _spring.stop(canceled: false);
    setState(() {
      _springing = false;
      _liveOffset = current;
      _decisionReserved = false;
    });
    _cardOffset.value = current;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_decisionSaving) return;
    _liveOffset += details.delta;
    _springing = false;
    _cardOffset.value = _liveOffset;
  }

  void _onPanEnd(DragEndDetails details) {
    if (_rawPointerCancelled) {
      _rawPointerCancelled = false;
      return;
    }
    if (_decisionSaving || _decisionReserved) return;
    final offset = _visibleOffset;
    final width = MediaQuery.sizeOf(context).width;
    final velocity = details.velocity.pixelsPerSecond.dx;
    // Distance is the single decision contract for both live feedback and
    // release. A quick flick below the visible threshold always returns.
    final direction = offset.dx.abs() >= swipeDecisionThreshold
        ? offset.dx.sign
        : 0.0;
    if (direction != 0) {
      final item = controller.current;
      if (item != null) {
        unawaited(
          _animateDecision(
            direction < 0 ? ReviewDecision.mark : ReviewDecision.keep,
            item,
            direction,
            velocity,
          ),
        );
      }
    } else {
      final epoch = ++_motionEpoch;
      unawaited(_springToPosition(Offset.zero, velocity / width, epoch));
    }
  }

  void _onRawPointerCancel() {
    _rawPointerCancelled = true;
    _onPanCancel();
  }

  void _onPanCancel() {
    if (_decisionSaving || _decisionReserved) return;
    final epoch = ++_motionEpoch;
    unawaited(_springToPosition(Offset.zero, 0, epoch));
  }

  Future<void> _decide(ReviewDecision decision, PhotoAsset item) =>
      _animateDecision(
        decision,
        item,
        decision == ReviewDecision.mark ? -1 : 1,
        0,
      );

  Future<void> _animateDecision(
    ReviewDecision decision,
    PhotoAsset item,
    double direction,
    double velocity,
  ) async {
    if (_decisionReserved || _decisionSaving) return;
    _decisionReserved = true;
    final epoch = ++_motionEpoch;
    setState(() {});
    final width = MediaQuery.sizeOf(context).width;
    final now = _visibleOffset;
    await _springToPosition(
      Offset(direction * width * 1.35, now.dy * .7),
      velocity / width,
      epoch,
    );
    if (!mounted || epoch != _motionEpoch) return;
    setState(() => _decisionSaving = true);
    final saved = await controller.decide(item, decision);
    if (!mounted) return;
    if (saved) {
      HapticFeedback.selectionClick();
    } else {
      HapticFeedback.vibrate();
    }
    setState(() {
      _decisionReserved = false;
      _decisionSaving = false;
      _springing = false;
      _liveOffset = Offset.zero;
    });
    _cardOffset.value = Offset.zero;
  }

  Future<void> _springToPosition(
    Offset target,
    double velocity,
    int epoch,
  ) async {
    final from = _visibleOffset;
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _springing = false;
      _liveOffset = target;
      _cardOffset.value = target;
      return;
    }
    _springFrom = from;
    _springTo = target;
    _springing = true;
    _spring.value = 0;
    final simulation = SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 340, damping: 32),
      0,
      1,
      velocity.clamp(-3, 3),
    );
    await _spring.animateWith(simulation);
    if (!mounted || epoch != _motionEpoch) return;
    _springing = false;
    _liveOffset = target;
    _cardOffset.value = target;
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({
    required this.controller,
    required this.reviewed,
    required this.total,
  });

  final SiftController controller;
  final int reviewed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final percent = total == 0 ? 0.0 : (reviewed / total).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              controller.demoMode ? 'Sample review' : 'Your review',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (controller.demoMode)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.tertiaryContainer,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  'FICTIONAL',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4,
                  ),
                ),
              ),
            Text(
              '$reviewed of $total',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(value: percent, minHeight: 4),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.controller});
  final SiftController controller;

  @override
  Widget build(BuildContext context) {
    final filters = controller.state.filters;
    final labels = <String>[
      if (filters.monthKey != null) _monthLabel(filters.monthKey!),
      if (filters.album != null) filters.album!,
      if (filters.screenshotsOnly) 'Screenshots',
    ];
    final summary = labels.isEmpty ? 'All photos' : labels.join(' · ');
    return FilledButton.tonal(
      key: const Key('filtersButton'),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _FilterSheet(controller: controller),
      ),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Row(
        children: [
          const Icon(Icons.tune_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Filters',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.keyboard_arrow_down_rounded),
        ],
      ),
    );
  }
}

class _FilterSheet extends StatelessWidget {
  const _FilterSheet({required this.controller});
  final SiftController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final items = controller.visibleAssets;
      final filters = controller.state.filters;
      final months =
          items
              .map((item) => item.captureDate)
              .whereType<DateTime>()
              .map(_monthKey)
              .toSet()
              .toList()
            ..sort((a, b) => b.compareTo(a));
      final albums =
          items.map((item) => item.album).whereType<String>().toSet().toList()
            ..sort();
      final unavailableMonth =
          filters.monthKey != null && !months.contains(filters.monthKey);
      final unavailableAlbum =
          filters.album != null && !albums.contains(filters.album);
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .86,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            key: const Key('filterSheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Filters',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Narrow the photos shown in your review.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              _FilterDrop<String?>(
                key: const Key('monthFilter'),
                hint: 'Month',
                value: filters.monthKey,
                items: <String?>[
                  null,
                  ...months,
                  if (unavailableMonth) filters.monthKey!,
                ],
                label: (value) => _monthFilterLabel(value, unavailableMonth),
                onChanged: (value) => controller.setFilters(
                  filters.copyWith(monthKey: value, clearMonth: value == null),
                ),
              ),
              const SizedBox(height: 12),
              _FilterDrop<String?>(
                key: const Key('albumFilter'),
                hint: 'Album',
                value: filters.album,
                items: <String?>[
                  null,
                  ...albums,
                  if (unavailableAlbum) filters.album!,
                ],
                label: (value) => _albumFilterLabel(value, unavailableAlbum),
                onChanged: (value) => controller.setFilters(
                  filters.copyWith(album: value, clearAlbum: value == null),
                ),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const Key('screenshotsFilter'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Screenshots'),
                subtitle: const Text('Uses a best-effort folder hint'),
                value: filters.screenshotsOnly,
                onChanged: (value) => controller.setFilters(
                  filters.copyWith(screenshotsOnly: value),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    key: const Key('resetFiltersButton'),
                    onPressed:
                        filters.monthKey == null &&
                            filters.album == null &&
                            !filters.screenshotsOnly
                        ? null
                        : () => controller.setFilters(const ReviewFilters()),
                    child: const Text('Reset'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _FilterDrop<T> extends StatelessWidget {
  const _FilterDrop({
    super.key,
    required this.hint,
    required this.value,
    required this.items,
    required this.label,
    required this.onChanged,
  });

  final String hint;
  final T? value;
  final List<T> items;
  final String Function(T? value) label;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: hint,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isExpanded: true,
        menuMaxHeight: 340,
        hint: Text(label(null)),
        items: items
            .map(
              (entry) => DropdownMenuItem<T>(
                value: entry,
                child: Text(
                  label(entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: onChanged,
      ),
    ),
  );
}

class _PhotoSummary extends StatelessWidget {
  const _PhotoSummary({
    required this.item,
    required this.demoMode,
    required this.gateway,
  });
  final PhotoAsset item;
  final bool demoMode;
  final SiftGateway gateway;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = item.captureDate == null
        ? 'Date unknown'
        : _dateLabel(item.captureDate!);
    final album = item.album ?? 'Album unknown';
    final size = item.sizeBytes == null
        ? 'Size unknown'
        : _sizeLabel(item.sizeBytes!);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                key: const Key('photoTitle'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$date · $album · $size',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          key: const Key('photoDetailsButton'),
          tooltip: 'Photo details',
          onPressed: () => _showPhotoDetails(context, item, demoMode, gateway),
          icon: const Icon(Icons.info_outline_rounded),
        ),
      ],
    );
  }
}

class _LimitedAccessNotice extends StatelessWidget {
  const _LimitedAccessNotice({required this.onManage});
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.secondaryContainer,
    borderRadius: BorderRadius.circular(16),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          const Icon(Icons.photo_library_outlined, size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Showing the photos you selected', maxLines: 2),
          ),
          TextButton(
            key: const Key('manageLimitedAccessButton'),
            onPressed: onManage,
            child: const Text('Change'),
          ),
        ],
      ),
    ),
  );
}

String _monthKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}';

String _monthLabel(String key) {
  final parts = key.split('-');
  if (parts.length != 2) return key;
  const names = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = int.tryParse(parts[1]) ?? 0;
  return month < 1 || month > 12 ? key : '${names[month - 1]} ${parts[0]}';
}

String _monthFilterLabel(String? value, bool unavailable) {
  if (value == null) return 'All months';
  return _monthLabel(value) + (unavailable ? ' · unavailable' : '');
}

String _albumFilterLabel(String? value, bool unavailable) {
  if (value == null) return 'All albums';
  return value + (unavailable ? ' · unavailable' : '');
}

class _SwipeCard extends StatelessWidget {
  const _SwipeCard({
    super.key,
    required this.item,
    required this.demoMode,
    required this.gateway,
    required this.upcoming,
    required this.allowPrefetch,
    required this.offsetListenable,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPanCancel,
    required this.onPointerCancel,
  });
  final PhotoAsset item;
  final bool demoMode;
  final SiftGateway gateway;
  final List<PhotoAsset> upcoming;
  final bool allowPrefetch;
  final ValueListenable<Offset> offsetListenable;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;
  final GestureDragCancelCallback onPanCancel;
  final VoidCallback onPointerCancel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          '${item.title}. ${item.album ?? 'Album unknown'}${item.captureDate == null ? '' : ', ${_dateLabel(item.captureDate!)}'}',
      hint: 'Swipe left to mark or right to keep. Buttons below provide the same actions.',
      child: Listener(
        onPointerCancel: (_) => onPointerCancel(),
        child: GestureDetector(
          key: const Key('swipeCardGesture'),
          behavior: HitTestBehavior.opaque,
          onPanStart: onPanStart,
          onPanUpdate: onPanUpdate,
          onPanEnd: onPanEnd,
          onPanCancel: onPanCancel,
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final detailMaxEdge = _imageTargetEdge(
                        constraints.biggest,
                        MediaQuery.devicePixelRatioOf(context),
                      );
                      if (!demoMode && allowPrefetch) {
                        PhotoArtwork.prefetch(
                          gateway,
                          current: item,
                          detailMaxEdge: detailMaxEdge,
                          upcoming: upcoming,
                        );
                      }
                      return PhotoArtwork(
                        item: item,
                        demoMode: demoMode,
                        gateway: gateway,
                        fit: BoxFit.contain,
                        maxEdge: detailMaxEdge,
                        preferSourceDetail: !demoMode,
                      );
                    },
                  ),
                ),
                Positioned.fill(
                  child: ValueListenableBuilder<Offset>(
                    valueListenable: offsetListenable,
                    builder: (context, offset, _) {
                      final progress = _swipeIntentProgress(offset.dx);
                      if (progress <= 0) return const SizedBox.shrink();
                      final marking = offset.dx < 0;
                      return Align(
                        // Keep the label on the edge opposite the card's travel
                        // so it remains visible as the photo moves away.
                        alignment: marking
                            ? Alignment.topRight
                            : Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Opacity(
                            opacity: progress,
                            child: Transform.scale(
                              scale: .94 + .06 * progress,
                              child: _DirectionStamp(marking: marking),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectionStamp extends StatelessWidget {
  const _DirectionStamp({required this.marking});
  final bool marking;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final semantic = Theme.of(context).extension<HirangSemanticColors>()!;
    final foreground = marking
        ? semantic.markForeground
        : semantic.keepForeground;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * .72,
      ),
      child: Material(
        key: const Key('swipeIntentStamp'),
        color: marking ? semantic.markBackground : semantic.keepBackground,
        elevation: 2,
        shadowColor: colors.shadow.withValues(alpha: .22),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                marking ? Icons.bookmark_add_rounded : Icons.check_rounded,
                color: foreground,
                size: 22,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  marking ? 'MARK FOR REMOVAL' : 'KEEP',
                  softWrap: true,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DecisionControls extends StatelessWidget {
  const _DecisionControls({
    required this.undoEnabled,
    required this.committing,
    required this.onMark,
    required this.onKeep,
    required this.onUndo,
  });

  final bool undoEnabled;
  final bool committing;
  final VoidCallback onMark;
  final VoidCallback onKeep;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<HirangSemanticColors>()!;
    ButtonStyle buttonStyle(Color background, Color foreground) =>
        FilledButton.styleFrom(
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest,
          disabledForegroundColor: Theme.of(context).colorScheme.onSurface
              .withValues(alpha: .38),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
          ),
        );
    return Row(
      children: [
        IconButton.filledTonal(
          key: const Key('undoButton'),
          onPressed: undoEnabled && !committing ? onUndo : null,
          tooltip: 'Undo last decision',
          icon: const Icon(Icons.undo_rounded),
          style: IconButton.styleFrom(
            minimumSize: const Size(46, 52),
            padding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            key: const Key('markButton'),
            onPressed: committing ? null : onMark,
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('Mark'),
            style: buttonStyle(
              semantic.markBackground,
              semantic.markForeground,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            key: const Key('keepButton'),
            onPressed: committing ? null : onKeep,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Keep'),
            style: buttonStyle(
              semantic.keepBackground,
              semantic.keepForeground,
            ),
          ),
        ),
      ],
    );
  }
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({
    required this.controller,
    required this.undoEnabled,
    required this.onUndo,
  });

  final SiftController controller;
  final bool undoEnabled;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.photo_library_outlined,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    'Choose photos to review',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Hirang works with local photos you choose. Your photos and review progress stay on this device.',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('openPhotoAccessButton'),
              onPressed: controller.loading ? null : controller.connectLibrary,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(
                controller.access.status == 'denied'
                    ? 'Choose local photos'
                    : 'Manage photo access',
              ),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
            ),
            if (controller.access.status == 'denied')
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('openSettingsButton'),
                    onPressed: controller.openAppSettings,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Open Android app settings'),
                  ),
                ),
              ),
            if (undoEnabled || controller.access.status == 'denied')
              Wrap(
                spacing: 8,
                children: [
                  if (undoEnabled)
                    TextButton.icon(
                      key: const Key('accessUndoButton'),
                      onPressed: onUndo,
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Undo last decision'),
                    ),
                  TextButton.icon(
                    key: const Key('trySampleDeckButton'),
                    onPressed: () => controller.setDemoMode(true),
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: const Text('Try sample deck'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _CaughtUpCard extends StatelessWidget {
  const _CaughtUpCard({
    required this.demoMode,
    required this.total,
    required this.hasAssets,
    required this.hasMarked,
    required this.hasFilters,
    required this.undoEnabled,
    required this.onUndo,
    required this.onOpenMarked,
    required this.onResetFilters,
    required this.onRefresh,
  });
  final bool demoMode;
  final int total;
  final bool hasAssets;
  final bool hasMarked;
  final bool hasFilters;
  final bool undoEnabled;
  final VoidCallback onUndo;
  final VoidCallback onOpenMarked;
  final VoidCallback onResetFilters;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final emptyFilteredView = total == 0 && hasFilters;
    final noAvailablePhotos = total == 0 && !hasAssets && !hasFilters;
    final title = total > 0
        ? 'You’re all caught up'
        : emptyFilteredView
        ? 'Nothing in this view'
        : noAvailablePhotos
        ? 'No photos available yet'
        : 'No photos to review right now';
    final detail = total > 0
        ? 'Your decisions are saved on this device. Review marked photos whenever you’re ready.'
        : emptyFilteredView
        ? 'Try another month or album, or reset the filters.'
        : noAvailablePhotos
        ? 'No photos are currently available in the library Hirang can read. Refresh or choose more photos from Photo options.'
        : 'There are no unreviewed photos in this view. Refresh the library or change its filters.';
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              total == 0
                  ? Icons.filter_alt_off_rounded
                  : Icons.check_circle_outline_rounded,
              size: 46,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            if (emptyFilteredView)
              TextButton(
                onPressed: onResetFilters,
                child: const Text('Reset filters'),
              ),
            if (undoEnabled)
              TextButton.icon(
                key: const Key('caughtUpUndoButton'),
                onPressed: onUndo,
                icon: const Icon(Icons.undo_rounded),
                label: const Text('Undo last decision'),
              ),
            if (noAvailablePhotos && !hasMarked)
              FilledButton.icon(
                key: const Key('emptyLibraryRefreshButton'),
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Refresh library'),
              )
            else
              FilledButton.icon(
                onPressed: onOpenMarked,
                icon: const Icon(Icons.bookmark_outline_rounded),
                label: const Text('Review marked'),
              ),
            if (demoMode)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'These are generated examples, not your library.',
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('retryButton'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LibraryRetryCard extends StatelessWidget {
  const _LibraryRetryCard({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 12),
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.sync_problem_rounded,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'Library needs another check',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          const Text(
            'Hirang could not confirm which photos are available. Your saved choices are unchanged. Check photo access or try refreshing again.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('libraryRetryCardButton'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry refresh'),
          ),
        ],
      ),
    ),
  );
}

String _dateLabel(DateTime date) =>
    '${_monthShort(date.month)} ${date.day}, ${date.year}';
String _monthShort(int month) => const [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month - 1];
String _sizeLabel(int bytes) => bytes < 1 << 20
    ? '${(bytes / 1024).round()} KB'
    : '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

class _SavedStateLoadFailure extends StatelessWidget {
  const _SavedStateLoadFailure({required this.loading, required this.onRetry});
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [BrandMark(size: 30), SizedBox(width: 10), Text('Hirang')],
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_clock_outlined,
                size: 46,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 18),
              Text(
                'Hirang could not safely check your saved review and trash status.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Your existing choices have not been changed. Retry before continuing.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('retrySavedStateButton'),
                onPressed: onRetry,
                icon: loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
                label: Text(loading ? 'Retrying…' : 'Retry'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum _HomeAction {
  manageAccess,
  refresh,
  appearance,
  settings,
  howItWorks,
  replayIntro,
}

Future<void> _showPhotoDetails(
  BuildContext context,
  PhotoAsset item,
  bool demoMode,
  SiftGateway gateway,
) async {
  final viewLarger = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.photo_outlined),
      title: const Text('Photo details'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(item.title),
          const SizedBox(height: 14),
          _DetailLine('Album', item.album ?? 'Unknown'),
          _DetailLine(
            'Date',
            item.captureDate == null
                ? 'Unknown'
                : _dateLabel(item.captureDate!),
          ),
          _DetailLine(
            'Estimated size',
            item.sizeBytes == null ? 'Unknown' : _sizeLabel(item.sizeBytes!),
          ),
          if (item.screenshotHeuristic)
            const _DetailLine(
              'Screenshot hint',
              'Possible match based on folder',
            ),
          if (demoMode)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('Generated sample. This is not a library photo.'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Close'),
        ),
        FilledButton.tonalIcon(
          key: const Key('viewPhotoLargerButton'),
          onPressed: () => Navigator.pop(dialogContext, true),
          icon: const Icon(Icons.zoom_out_map_rounded),
          label: const Text('View photo larger'),
        ),
      ],
    ),
  );
  if (viewLarger != true || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) =>
        _PhotoLargerDialog(item: item, demoMode: demoMode, gateway: gateway),
  );
}

class _PhotoLargerDialog extends StatelessWidget {
  const _PhotoLargerDialog({
    required this.item,
    required this.demoMode,
    required this.gateway,
  });

  final PhotoAsset item;
  final bool demoMode;
  final SiftGateway gateway;

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: IconButton(
          tooltip: 'Close photo preview',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: LayoutBuilder(
                    builder: (context, constraints) => PhotoArtwork(
                      item: item,
                      demoMode: demoMode,
                      gateway: gateway,
                      fit: BoxFit.contain,
                      maxEdge: _imageTargetEdge(
                        constraints.biggest,
                        MediaQuery.devicePixelRatioOf(context),
                      ),
                      preferSourceDetail: !demoMode,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                demoMode
                    ? 'Generated sample · no library photo is used'
                    : 'Private preview · image stays on this device',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

Future<void> _showHowItWorks(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    title: const Text('How Hirang works'),
    content: const Text(
      'Swipe right or tap Keep to save a local review decision. Swipe left or tap Mark to add a photo to your marked queue; marking does not change the photo. Moving marked photos to system trash requires confirmation in Hirang and Android. Hirang has no permanent-delete action and cannot promise when trash will expire or how much storage will be freed. Photos and review progress stay on this device.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Got it'),
      ),
    ],
  ),
);
