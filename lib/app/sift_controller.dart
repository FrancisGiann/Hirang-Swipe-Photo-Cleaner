import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/demo_fixtures.dart';
import 'brand.dart';
import '../domain/hirang_theme_id.dart';
import '../domain/review_state.dart';
import '../platform/sift_gateway.dart';

class SiftController extends ChangeNotifier {
  SiftController(this.gateway);

  final SiftGateway gateway;
  final ValueNotifier<HirangThemeId> themeSelection = ValueNotifier(
    HirangThemeId.amihan,
  );
  ReviewState state = ReviewState.initial();
  PhotoAccess access = const PhotoAccess(status: 'denied', sdkInt: 0);
  List<PhotoAsset> assets = const [];
  String? _photoCursor;
  bool hasMorePhotos = false;
  bool loadingMorePhotos = false;
  String photoPageStatus = 'ready';
  String? photoPageMessage;
  bool initialized = false;
  bool stateLoaded = false;
  bool startupReady = false;
  bool loading = false;
  bool _initializing = false;
  bool _decisionBusy = false;
  bool _operationBusy = false;
  Future<void> _writeTail = Future<void>.value();
  int _operationRevision = 0;
  int _operationRefreshRevision = 0;
  int _assetRefreshRevision = 0;
  int _cleanupAvailabilityRevision = 0;
  int _cleanupSessionStartRevision = 0;
  int photoCatalogRevision = 0;
  final Set<String> _closedOperationIds = {};
  final Set<String> _unconfirmedCleanupIds = {};
  String? error;

  bool get demoMode => state.demoMode;
  List<PhotoAsset> get visibleAssets => demoMode ? DemoFixtures.items : assets;
  PhotoAsset? get current => state.nextUnreviewed(visibleAssets);
  List<PhotoAsset> get marked => state.markedAssets();
  bool cleanupItemConfirmed(String id) => !_unconfirmedCleanupIds.contains(id);

  Future<void> initialize() async {
    if (_initializing) return;
    _initializing = true;
    loading = true;
    notifyListeners();
    try {
      state = await gateway.loadState();
      themeSelection.value = state.themeId;
      stateLoaded = true;
      access = await gateway.permissionStatus();
      final nativeOperation = await gateway.readTrashOperation();
      if (nativeOperation != null) {
        await _mutate((current) => current.updateOperation(nativeOperation));
        if (nativeOperation.status == 'resultReceived' ||
            nativeOperation.status == 'prepared') {
          final reconciled = await gateway.reconcileTrashOperation(
            operationId: nativeOperation.id,
          );
          if (reconciled != null) {
            await _mutate((current) => current.updateOperation(reconciled));
          }
        }
      } else if (state.operation?.isActive ?? false) {
        // Native journals before any system request; no native record means no prompt was launched.
        await _mutate((current) {
          final orphan = current.operation;
          if (orphan == null) return current;
          final outcomes =
              Map<String, OperationItemOutcome>.from(orphan.outcomes)
                ..updateAll(
                  (_, value) => value == OperationItemOutcome.pending
                      ? OperationItemOutcome.unknown
                      : value,
                );
          return current.updateOperation(
            orphan.copyWith(status: 'interrupted', outcomes: outcomes),
          );
        });
      }
      startupReady = true;
      await _refreshAssets();
      error = null;
    } catch (_) {
      error =
          '$appDisplayName could not safely load saved review status. Please retry.';
    } finally {
      loading = false;
      initialized = true;
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> _refreshAssets() async {
    if (!stateLoaded) return;
    photoCatalogRevision++;
    final refreshRevision = ++_assetRefreshRevision;
    final requestedDemoMode = state.demoMode;
    final requestedAccessStatus = access.status;
    bool stillCurrent() =>
        refreshRevision == _assetRefreshRevision &&
        requestedDemoMode == state.demoMode &&
        requestedAccessStatus == access.status;

    if (requestedDemoMode) {
      if (stillCurrent()) {
        assets = DemoFixtures.items;
        _photoCursor = null;
        hasMorePhotos = false;
        photoPageStatus = 'ready';
        photoPageMessage = null;
      }
    } else if (access.canRead) {
      final appliedEventsAtSnapshot = {
        for (final entry in state.appliedTrashOutcomes.entries)
          entry.key: Set<String>.from(entry.value),
      };
      late final List<PhotoAsset> queriedAssets;
      if (gateway case final PagedPhotoGateway pagedGateway) {
        final page = await pagedGateway.queryPhotoPage(
          mode: PhotoQueryMode.recent,
          pageSize: 60,
          filters: state.filters,
        );
        if (!stillCurrent()) return;
        queriedAssets = page.items;
        _photoCursor = page.cursor;
        hasMorePhotos = page.hasMore;
        photoPageStatus = page.status;
        photoPageMessage = page.message;
        if (page.hasMore && page.cursor == null) {
          hasMorePhotos = false;
          photoPageStatus = 'unsupported';
          photoPageMessage =
              'MediaStore did not return a safe continuation cursor.';
        }
        if (!page.isSupported) {
          error = page.status == 'stale'
              ? 'The photo list changed. Refresh to start a new page.'
              : 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
        }
      } else {
        queriedAssets = await gateway.queryPhotos();
        if (!stillCurrent()) return;
        _photoCursor = null;
        hasMorePhotos = false;
        photoPageStatus = 'ready';
        photoPageMessage = null;
      }
      if (!stillCurrent()) return;
      assets = List.unmodifiable(queriedAssets);
      if (queriedAssets.isNotEmpty && state.terminalTrashedIds.isNotEmpty) {
        await _mutate(
          (current) => !stillCurrent() || current.demoMode
              ? current
              : current.reconcileRestoredAssets(
                  queriedAssets,
                  appliedEventsAtSnapshot: appliedEventsAtSnapshot,
                ),
        );
      }
      await _refreshCleanupAvailability();
    } else {
      if (stillCurrent()) {
        assets = const [];
        _photoCursor = null;
        hasMorePhotos = false;
        photoPageStatus = 'denied';
        photoPageMessage = null;
      }
      await _markPendingCleanupItemsUnconfirmed();
    }
  }

  Future<void> loadMorePhotos() async {
    if (!startupReady ||
        loadingMorePhotos ||
        !hasMorePhotos ||
        demoMode ||
        !access.canRead ||
        gateway is! PagedPhotoGateway) {
      return;
    }
    final cursor = _photoCursor;
    if (cursor == null) return;
    final refreshRevision = _assetRefreshRevision;
    final requestedAccess = access.status;
    final requestedFilters = _filtersKey(state.filters);
    bool catalogStillCurrent() =>
        refreshRevision == _assetRefreshRevision &&
        requestedAccess == access.status &&
        requestedFilters == _filtersKey(state.filters) &&
        !state.demoMode;
    final appliedEventsAtSnapshot = {
      for (final entry in state.appliedTrashOutcomes.entries)
        entry.key: Set<String>.from(entry.value),
    };
    loadingMorePhotos = true;
    notifyListeners();
    try {
      final page = await (gateway as PagedPhotoGateway).queryPhotoPage(
        mode: PhotoQueryMode.recent,
        pageSize: 60,
        cursor: cursor,
        filters: state.filters,
      );
      bool stillCurrent() =>
          catalogStillCurrent() && cursor == _photoCursor;
      if (!stillCurrent()) return;
      if (page.status == 'stale') {
        await _refreshAssets();
        return;
      }
      final earlierPageWasPartial = photoPageStatus == 'partial';
      photoPageStatus =
          page.isSupported && (page.isPartial || earlierPageWasPartial)
          ? 'partial'
          : page.status;
      photoPageMessage = photoPageStatus == 'partial'
          ? 'Some photos in the loaded pages could not be checked.'
          : page.message;
      if (!page.isSupported) {
        hasMorePhotos = false;
        error = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
        return;
      }
      if (page.hasMore && page.cursor == null) {
        hasMorePhotos = false;
        photoPageStatus = 'unsupported';
        photoPageMessage =
            'MediaStore did not return a safe continuation cursor.';
        error = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
        return;
      }
      final seen = assets.map((item) => item.id).toSet();
      assets = List.unmodifiable([
        ...assets,
        ...page.items.where((item) => seen.add(item.id)),
      ]);
      _photoCursor = page.cursor;
      hasMorePhotos = page.hasMore;
      if (page.items.isNotEmpty && state.terminalTrashedIds.isNotEmpty) {
        await _mutate(
          (current) => !catalogStillCurrent() || current.demoMode
              ? current
              : current.reconcileRestoredAssets(
                  page.items,
                  appliedEventsAtSnapshot: appliedEventsAtSnapshot,
                ),
        );
      }
      await _refreshCleanupAvailability();
    } catch (_) {
      if (refreshRevision == _assetRefreshRevision) {
        photoPageStatus = 'error';
        photoPageMessage = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
        error = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
      }
    } finally {
      loadingMorePhotos = false;
      notifyListeners();
    }
  }

  String _filtersKey(ReviewFilters filters) =>
      '${filters.monthKey}|${filters.album}|${filters.screenshotsOnly}';

  Map<String, Set<String>> appliedTrashOutcomesSnapshot() => {
    for (final entry in state.appliedTrashOutcomes.entries)
      entry.key: Set<String>.from(entry.value),
  };

  Future<void> reconcileToolPage({
    required List<PhotoAsset> items,
    required Map<String, Set<String>> appliedEventsAtSnapshot,
    required int expectedCatalogRevision,
    required String expectedAccess,
  }) async {
    if (items.isEmpty ||
        state.demoMode ||
        !access.canRead ||
        access.status != expectedAccess ||
        photoCatalogRevision != expectedCatalogRevision) {
      return;
    }
    await _mutate(
      (current) =>
          !current.demoMode &&
              access.canRead &&
              access.status == expectedAccess &&
              photoCatalogRevision == expectedCatalogRevision
          ? current.reconcileRestoredAssets(
              items,
              appliedEventsAtSnapshot: appliedEventsAtSnapshot,
            )
          : current,
    );
  }

  Future<void> _refreshCleanupAvailability() async {
    final session = state.cleanupSession;
    if (session == null || !session.isActive || session.demoMode != demoMode) {
      return;
    }
    final revision = ++_cleanupAvailabilityRevision;
    final expectedAccess = access.status;
    final expectedAssetRevision = _assetRefreshRevision;
    if (session.demoMode) {
      _unconfirmedCleanupIds.removeAll(session.items.map((item) => item.id));
      await _mutate(
        (current) => revision == _cleanupAvailabilityRevision
            ? current.updateCleanupAvailability(session.id, {
                for (final item in session.items)
                  item.id: CleanupAvailability.available,
              })
            : current,
      );
      return;
    }
    _unconfirmedCleanupIds.addAll(
      session.items
          .where((item) => !state.decisions.containsKey(item.id))
          .map((item) => item.id),
    );
    notifyListeners();
    if (!access.canRead) {
      await _markPendingCleanupItemsUnconfirmed(
        session: session,
        revision: revision,
        expectedAccess: expectedAccess,
        expectedAssetRevision: expectedAssetRevision,
      );
      return;
    }
    final expectedSessionId = session.id;
    bool stillCurrent(ReviewState current) =>
        revision == _cleanupAvailabilityRevision &&
        current.cleanupSession?.id == expectedSessionId &&
        current.cleanupSession?.isActive == true &&
        current.demoMode == session.demoMode &&
        access.canRead &&
        access.status == expectedAccess &&
        _assetRefreshRevision == expectedAssetRevision;
    try {
      final results = await gateway.revalidate(session.items);
      final statuses = {for (final result in results) result.id: result.status};
      if (stillCurrent(state)) {
        for (final item in session.items) {
          if (statuses[item.id] == 'present') {
            _unconfirmedCleanupIds.remove(item.id);
          } else {
            _unconfirmedCleanupIds.add(item.id);
          }
        }
        notifyListeners();
      }
      await _mutate(
        (current) => current.updateCleanupAvailability(
          expectedSessionId,
          stillCurrent(current)
              ? {
                  for (final item in session.items)
                    item.id: statuses[item.id] == 'present'
                        ? CleanupAvailability.available
                        : CleanupAvailability.unconfirmed,
                }
              : const {},
        ),
      );
    } catch (_) {
      await _markPendingCleanupItemsUnconfirmed(
        session: session,
        revision: revision,
        expectedAccess: expectedAccess,
        expectedAssetRevision: expectedAssetRevision,
      );
    }
  }

  Future<void> _markPendingCleanupItemsUnconfirmed({
    CleanupSession? session,
    int? revision,
    String? expectedAccess,
    int? expectedAssetRevision,
  }) async {
    final active = session ?? state.cleanupSession;
    if (active == null || !active.isActive || active.demoMode != demoMode) {
      return;
    }
    _unconfirmedCleanupIds.addAll(
      active.items
          .where((item) => !state.decisions.containsKey(item.id))
          .map((item) => item.id),
    );
    notifyListeners();
    final expectedSessionId = active.id;
    await _mutate((current) {
      if (revision != null && revision != _cleanupAvailabilityRevision) {
        return current;
      }
      if (expectedAccess != null && access.status != expectedAccess) {
        return current;
      }
      if (expectedAssetRevision != null &&
          _assetRefreshRevision != expectedAssetRevision) {
        return current;
      }
      if (current.cleanupSession?.id != expectedSessionId ||
          current.cleanupSession?.isActive != true ||
          current.demoMode != active.demoMode) {
        return current;
      }
      return current.updateCleanupAvailability(expectedSessionId, {
        for (final item in active.items)
          if (!current.decisions.containsKey(item.id))
            item.id: CleanupAvailability.unconfirmed,
      });
    });
  }

  Future<void> setDemoMode(bool enabled) async {
    if (!startupReady) return;
    if (enabled != demoMode && state.cleanupSession?.isActive == true) {
      error = 'Finish the current cleanup session before changing photo decks.';
      notifyListeners();
      return;
    }
    if (_operationBusy || (state.operation?.isActive ?? false)) return;
    try {
      await _mutate((current) => current.copyWith(demoMode: enabled));
      if (!enabled) {
        access = await gateway.permissionStatus();
        await refreshOperation();
      }
      await _refreshAssets();
      error = null;
    } catch (_) {
      error = 'The selected deck could not be saved. Please try again.';
    }
    notifyListeners();
  }

  Future<void> connectLibrary() async {
    if (!startupReady) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      access = await gateway.requestPhotoAccess();
      if (access.canRead) {
        if (state.demoMode) {
          await _mutate((current) => current.copyWith(demoMode: false));
        }
        await refreshOperation();
      }
      await _refreshAssets();
    } catch (_) {
      error = 'Photo access could not be checked. Please retry.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshFromSystem() async {
    if (!startupReady) return;
    photoCatalogRevision++;
    notifyListeners();
    try {
      access = await gateway.permissionStatus();
      await refreshOperation();
      await _refreshAssets();
      error = null;
    } catch (_) {
      photoPageStatus = 'error';
      photoPageMessage = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
      error =
          '$appDisplayName could not refresh your local photo library. Check photo access and retry.';
    }
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    if (!startupReady) {
      error = 'Saved review progress is not available yet. Retry loading before continuing.';
      notifyListeners();
      return;
    }
    try {
      await _mutate(
        (current) => current.onboardingComplete
            ? current
            : current.copyWith(onboardingComplete: true),
      );
      error = null;
    } catch (_) {
      error = 'The introduction could not be saved. Please try again.';
    }
    notifyListeners();
  }

  Future<bool> selectTheme(HirangThemeId theme) async {
    if (!startupReady) {
      error = 'Saved review status is still loading. Please retry before changing appearance.';
      notifyListeners();
      return false;
    }
    if (state.themeId == theme) return true;
    try {
      await _mutate((current) => current.copyWith(themeId: theme));
      error = null;
      return true;
    } catch (_) {
      error = 'Appearance could not be saved. Your previous choice is still active; try again.';
      return false;
    } finally {
      notifyListeners();
    }
  }

  Future<void> openAppSettings() async {
    try {
      await gateway.openAppSettings();
      error = null;
    } catch (_) {
      error = 'Android app settings could not be opened. You can open them from Android settings.';
    }
    notifyListeners();
  }

  Future<void> refreshOperation({bool afterSystemScreenClosed = false}) async {
    if (!startupReady) return;
    final operationRevision = _operationRevision;
    final refreshRevision = ++_operationRefreshRevision;
    final native = await gateway.readTrashOperation();
    if (native == null) return;
    bool stillCurrent(ReviewState current) =>
        operationRevision == _operationRevision &&
        refreshRevision == _operationRefreshRevision &&
        !_closedOperationIds.contains(native.id) &&
        (current.operation == null || current.operation!.id == native.id);

    await _mutate(
      (current) =>
          stillCurrent(current) ? current.updateOperation(native) : current,
    );
    if (operationRevision != _operationRevision ||
        refreshRevision != _operationRefreshRevision ||
        _closedOperationIds.contains(native.id) ||
        (state.operation != null && state.operation!.id != native.id)) {
      return;
    }
    final shouldReconcile =
        native.status == 'resultReceived' ||
        native.status == 'prepared' ||
        (native.status == 'awaitingSystemApproval' && afterSystemScreenClosed);
    if (shouldReconcile) {
      final reconciled = await gateway.reconcileTrashOperation(
        operationId: native.id,
        afterSystemScreenClosed: afterSystemScreenClosed,
      );
      if (reconciled != null) {
        await _mutate(
          (current) => stillCurrent(current) && reconciled.id == native.id
              ? current.updateOperation(reconciled)
              : current,
        );
      }
    }
  }

  Future<void> setFilters(ReviewFilters filters) async {
    if (!startupReady) return;
    try {
      await _mutate((current) => current.withFilters(filters));
      if (gateway is PagedPhotoGateway && !demoMode && access.canRead) {
        await _refreshAssets();
      }
      error = null;
    } catch (_) {
      error = 'Filters could not be saved. Please try again.';
    }
    notifyListeners();
  }

  Future<bool> decide(PhotoAsset item, ReviewDecision decision) async {
    if (!startupReady ||
        _decisionBusy ||
        (state.operation?.locks(item.id) ?? false)) {
      return false;
    }
    _decisionBusy = true;
    try {
      await _mutate((current) => current.decide(item, decision));
      error = null;
      return true;
    } on Object catch (_) {
      error = 'Your choice could not be saved. Please try again.';
      return false;
    } finally {
      _decisionBusy = false;
      notifyListeners();
    }
  }

  Future<bool> decideVerified(PhotoAsset item, ReviewDecision decision) async {
    if (!startupReady ||
        _decisionBusy ||
        (state.operation?.locks(item.id) ?? false)) {
      return false;
    }
    if (demoMode) return decide(item, decision);
    if (!access.canRead) {
      error =
          'Photo access is unavailable. Your saved decisions are unchanged.';
      notifyListeners();
      return false;
    }
    _decisionBusy = true;
    final requestedAccess = access.status;
    final expectedSessionId = state.cleanupSession?.id;
    try {
      final results = await gateway.revalidate([item]);
      final stillSameDeck =
          !demoMode &&
          access.canRead &&
          access.status == requestedAccess &&
          (expectedSessionId == null ||
              state.cleanupSession?.id == expectedSessionId);
      if (!stillSameDeck ||
          !results.any((result) => result.id == item.id && result.isPresent)) {
        if (expectedSessionId != null) {
          await _mutate(
            (current) => current.updateCleanupAvailability(expectedSessionId, {
              item.id: CleanupAvailability.unconfirmed,
            }),
          );
        }
        error = 'This photo is no longer confirmed as accessible. Its existing decision is unchanged.';
        return false;
      }
      if (state.cleanupSession case final session?
          when session.isActive &&
              session.items.any(
                (member) =>
                    member.id == item.id && member.hasSameStableIdentity(item),
              )) {
        await _mutate(
          (current) => current.updateCleanupAvailability(session.id, {
            item.id: CleanupAvailability.available,
          }),
        );
      }
      await _mutate((current) => current.decide(item, decision));
      error = null;
      return true;
    } catch (_) {
      error =
          'This photo could not be safely checked. Your choice was not saved.';
      return false;
    } finally {
      _decisionBusy = false;
      notifyListeners();
    }
  }

  Future<bool> startCleanupSession({
    required CleanupSessionKind kind,
    String? monthKey,
    int batchSize = 20,
  }) async {
    if (!startupReady || state.cleanupSession?.isActive == true) return false;
    final requestRevision = ++_cleanupSessionStartRevision;
    final safeBatchSize = batchSize.clamp(1, 20).toInt();
    final mode = demoMode;
    final originalSessionId = state.cleanupSession?.id;
    final requestedAccess = access.status;
    final requestedCatalogRevision = photoCatalogRevision;
    final sourceMode = kind == CleanupSessionKind.screenshots
        ? PhotoQueryMode.screenshotHints
        : PhotoQueryMode.recent;
    final cursorScope = '${sourceMode.name}|$monthKey|$mode';
    late final List<PhotoAsset> candidates;
    String? nextCursor;
    var partialPage = false;
    if (mode) {
      candidates = DemoFixtures.items;
    } else {
      if (!access.canRead) {
        error = 'Choose photo access before starting a library session.';
        notifyListeners();
        return false;
      }
      if (gateway is! PagedPhotoGateway) {
        error = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
        notifyListeners();
        return false;
      }
      try {
        final previousCursor = state.cleanupCursorScope == cursorScope
            ? state.cleanupPageCursor
            : null;
        var page = await (gateway as PagedPhotoGateway).queryPhotoPage(
          mode: sourceMode,
          pageSize: safeBatchSize,
          cursor: previousCursor,
          filters: ReviewFilters(monthKey: monthKey),
        );
        if (page.status == 'stale' && previousCursor != null) {
          page = await (gateway as PagedPhotoGateway).queryPhotoPage(
            mode: sourceMode,
            pageSize: safeBatchSize,
            filters: ReviewFilters(monthKey: monthKey),
          );
        }
        if (requestRevision != _cleanupSessionStartRevision ||
            mode != demoMode ||
            !access.canRead ||
            access.status != requestedAccess ||
            photoCatalogRevision != requestedCatalogRevision ||
            state.cleanupSession?.id != originalSessionId) {
          return false;
        }
        if (!page.isSupported) {
          error = page.status == 'stale'
              ? 'The photo list changed. Refresh and start again.'
              : 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
          notifyListeners();
          return false;
        }
        if (page.hasMore && page.cursor == null) {
          error = 'Could not load this photo list safely. Refresh to retry; saved decisions remain.';
          notifyListeners();
          return false;
        }
        candidates = page.items;
        nextCursor = page.hasMore ? page.cursor : null;
        partialPage = page.isPartial;
      } catch (_) {
        error = 'Photos could not be loaded for a cleanup session.';
        notifyListeners();
        return false;
      }
    }
    final eligible =
        ReviewFilters(
              monthKey: monthKey,
              screenshotsOnly: kind == CleanupSessionKind.screenshots,
            )
            .apply(candidates)
            .where(
              (item) =>
                  !state.decisions.containsKey(item.id) &&
                  !state.terminalTrashedIds.contains(item.id),
            );
    final batch = eligible.take(safeBatchSize).toList(growable: false);
    if (batch.isEmpty) {
      if (!mode && !partialPage) {
        var cursorWasSaved = false;
        try {
          await _mutate((current) {
            if (requestRevision != _cleanupSessionStartRevision ||
                current.demoMode != mode ||
                current.cleanupSession?.id != originalSessionId ||
                !access.canRead ||
                access.status != requestedAccess ||
                photoCatalogRevision != requestedCatalogRevision) {
              return current;
            }
            cursorWasSaved = true;
            return current.setCleanupPageCursor(nextCursor, cursorScope);
          });
        } catch (_) {
          error = 'Could not save this photo list. Refresh to retry; saved decisions remain.';
          notifyListeners();
          return false;
        }
        if (!cursorWasSaved) return false;
      }
      error = partialPage
          ? 'This page was incomplete. Refresh access before reporting this date group as reviewed.'
          : nextCursor != null
          ? 'This page has no unreviewed photos. Continue to the next page.'
          : kind == CleanupSessionKind.screenshots
          ? 'No unreviewed screenshot hints were returned on this page. Starting again rechecks earlier pages.'
          : 'No unreviewed photos were returned on this page. Starting again rechecks earlier pages.';
      notifyListeners();
      return false;
    }
    try {
      await _mutate((current) {
        if (requestRevision != _cleanupSessionStartRevision ||
            current.demoMode != mode ||
            current.cleanupSession?.id != originalSessionId ||
            (!mode &&
                (!access.canRead ||
                    access.status != requestedAccess ||
                    photoCatalogRevision != requestedCatalogRevision))) {
          throw StateError('The photo deck changed while starting a session.');
        }
        return current.startCleanupSession(
          sessionId:
              '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${UniqueKey().hashCode.toRadixString(36)}',
          nowMillis: DateTime.now().millisecondsSinceEpoch,
          kind: kind,
          items: batch,
          nextCursor: mode ? null : nextCursor,
          cursorScope: cursorScope,
          sourcePagePartial: partialPage,
          monthKey: monthKey,
        );
      });
      _unconfirmedCleanupIds.removeAll(batch.map((item) => item.id));
      error = null;
      return true;
    } catch (_) {
      error =
          'The cleanup session could not be saved. No photo decision changed.';
      return false;
    } finally {
      notifyListeners();
    }
  }

  Future<void> resumeCleanupSession() async {
    if (!startupReady) return;
    final session = state.cleanupSession;
    if (session == null || !session.isActive || session.demoMode != demoMode) {
      return;
    }
    await _refreshCleanupAvailability();
    notifyListeners();
  }

  Future<void> finishCleanupSession() async {
    final session = state.cleanupSession;
    if (!startupReady || session == null || !session.isActive) return;
    try {
      await _mutate(
        (current) => current.finishCleanupSession(
          session.id,
          DateTime.now().millisecondsSinceEpoch,
        ),
      );
      error = null;
    } catch (_) {
      error = 'The cleanup session could not be finished. Its snapshot remains available.';
    }
    notifyListeners();
  }

  Future<void> undo() async {
    if (!startupReady || _decisionBusy || !state.canUndo) return;
    _decisionBusy = true;
    try {
      await _mutate((current) => current.undo());
      error = null;
    } catch (_) {
      error = 'Undo could not be saved. Please try again.';
    } finally {
      _decisionBusy = false;
      notifyListeners();
    }
  }

  Future<void> unmark(String id) async {
    if (!startupReady ||
        _decisionBusy ||
        (state.operation?.locks(id) ?? false)) {
      return;
    }
    _decisionBusy = true;
    try {
      await _mutate((current) => current.unmark(id));
      error = null;
    } catch (_) {
      error = 'This mark could not be changed. Please try again.';
    } finally {
      _decisionBusy = false;
      notifyListeners();
    }
  }

  Future<Map<String, Revalidation>> revalidateMarked({
    List<PhotoAsset>? selection,
  }) async {
    if (!startupReady || demoMode || !access.canRead) return const {};
    final frozenSelection = List<PhotoAsset>.unmodifiable(selection ?? marked);
    final results = await gateway.revalidate(frozenSelection);
    return {for (final result in results) result.id: result};
  }

  Future<void> beginTrash({List<String>? expectedItemIds}) async {
    if (!startupReady ||
        _operationBusy ||
        demoMode ||
        !access.canRead ||
        state.operation?.isActive == true) {
      return;
    }
    _operationBusy = true;
    final operationRevision = ++_operationRevision;
    final expectedIds = expectedItemIds == null
        ? null
        : List<String>.unmodifiable(expectedItemIds);
    var selectionChanged = false;
    TrashOperation? submitted;
    notifyListeners();
    try {
      await _mutate((current) {
        if (current.demoMode || current.operation?.isActive == true) {
          throw StateError('The current deck cannot start a trash request.');
        }
        final currentItems = List<PhotoAsset>.of(current.markedAssets());
        final currentIds = currentItems.map((item) => item.id).toSet();
        final requestedIds = expectedIds?.toSet();
        if (expectedIds != null &&
            (currentItems.length != expectedIds.length ||
                requestedIds!.length != expectedIds.length ||
                !setEquals(currentIds, requestedIds))) {
          selectionChanged = true;
          throw StateError('The marked selection changed during confirmation.');
        }
        final started = current.beginTrashOperation(
          operationId:
              '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${UniqueKey().hashCode.toRadixString(36)}',
          nowMillis: DateTime.now().millisecondsSinceEpoch,
          items: currentItems,
        );
        submitted = started.operation!;
        return started;
      });
      final operationToSubmit = submitted!;
      final native = await gateway.beginTrashOperation(operationToSubmit);
      if (native == null || native.id != operationToSubmit.id) {
        throw StateError('The system did not return the submitted journal.');
      }
      if (native.id == operationToSubmit.id) {
        await _mutate(
          (current) =>
              operationRevision == _operationRevision &&
                  current.operation?.id == operationToSubmit.id
              ? current.updateOperation(native)
              : current,
        );
      }
      error = null;
    } catch (_) {
      final native = await gateway.readTrashOperation();
      final submittedId = submitted?.id;
      if (operationRevision == _operationRevision &&
          submittedId != null &&
          native != null &&
          native.id == submittedId) {
        await _mutate(
          (current) => current.operation?.id == submittedId
              ? current.updateOperation(native)
              : current,
        );
      } else if (operationRevision == _operationRevision &&
          submittedId != null) {
        await _mutate((current) {
          final operation = current.operation;
          if (operation == null || operation.id != submittedId) return current;
          final outcomes = {
            for (final item in operation.items)
              item.id: OperationItemOutcome.unknown,
          };
          return current.updateOperation(
            operation.copyWith(status: 'interrupted', outcomes: outcomes),
          );
        });
      }
      error = selectionChanged
          ? 'The marked selection changed while it was being checked. Review the current selection and confirm again.'
          : 'The system trash request could not start. Your photos remain marked; review and try again.';
    } finally {
      _operationBusy = false;
      notifyListeners();
    }
  }

  Future<void> continueTrash() async {
    if (!startupReady || _operationBusy) return;
    final operation = state.operation;
    if (operation == null ||
        operation.status != 'needsContinue' ||
        demoMode ||
        !access.canRead) {
      return;
    }
    _operationBusy = true;
    final operationRevision = ++_operationRevision;
    notifyListeners();
    try {
      final native = await gateway.continueTrashOperation(operation.id);
      if (native != null) {
        await _mutate(
          (current) =>
              operationRevision == _operationRevision &&
                  current.operation?.id == operation.id &&
                  native.id == operation.id
              ? current.updateOperation(native)
              : current,
        );
      }
      error = null;
    } catch (_) {
      error = 'The next group could not start. Review the selected photos and try again.';
    } finally {
      _operationBusy = false;
      notifyListeners();
    }
  }

  Future<void> clearFinishedOperation() async {
    if (!startupReady || _operationBusy) return;
    final operation = state.operation;
    if (operation == null || operation.isActive) return;
    _operationBusy = true;
    final operationRevision = ++_operationRevision;
    try {
      await gateway.clearTrashOperation(operation.id);
      _closedOperationIds.add(operation.id);
      await _mutate(
        (current) =>
            operationRevision == _operationRevision &&
                current.operation?.id == operation.id &&
                !current.operation!.isActive
            ? current.clearFinishedOperation()
            : current,
      );
      ++_operationRevision;
      error = null;
    } catch (_) {
      error = 'The result could not be closed. Please try again.';
    } finally {
      _operationBusy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    themeSelection.dispose();
    super.dispose();
  }

  Future<ReviewState> _mutate(
    ReviewState Function(ReviewState current) transform,
  ) {
    final completer = Completer<ReviewState>();
    _writeTail = _writeTail.catchError((Object _) {}).then((_) async {
      try {
        if (!stateLoaded || (!startupReady && !_initializing)) {
          throw StateError('Saved review and trash status have not loaded.');
        }
        final next = transform(state);
        await gateway.saveState(next);
        final previousTheme = state.themeId;
        state = next;
        if (next.themeId != previousTheme) themeSelection.value = next.themeId;
        completer.complete(next);
      } catch (exception, stackTrace) {
        completer.completeError(exception, stackTrace);
      }
      notifyListeners();
    });
    return completer.future;
  }
}
