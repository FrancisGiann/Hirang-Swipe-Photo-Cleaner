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
  final Set<String> _closedOperationIds = {};
  String? error;

  bool get demoMode => state.demoMode;
  List<PhotoAsset> get visibleAssets => demoMode ? DemoFixtures.items : assets;
  PhotoAsset? get current => state.nextUnreviewed(visibleAssets);
  List<PhotoAsset> get marked => state.markedAssets();

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
    final refreshRevision = ++_assetRefreshRevision;
    final requestedDemoMode = state.demoMode;
    final requestedAccessStatus = access.status;
    bool stillCurrent() =>
        refreshRevision == _assetRefreshRevision &&
        requestedDemoMode == state.demoMode &&
        requestedAccessStatus == access.status;

    if (requestedDemoMode) {
      if (stillCurrent()) assets = DemoFixtures.items;
    } else if (access.canRead) {
      final appliedEventsAtSnapshot = {
        for (final entry in state.appliedTrashOutcomes.entries)
          entry.key: Set<String>.from(entry.value),
      };
      final queriedAssets = await gateway.queryPhotos();
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
    } else {
      if (stillCurrent()) assets = const [];
    }
  }

  Future<void> setDemoMode(bool enabled) async {
    if (!startupReady) return;
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
    try {
      access = await gateway.permissionStatus();
      await refreshOperation();
      await _refreshAssets();
      error = null;
    } catch (_) {
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
