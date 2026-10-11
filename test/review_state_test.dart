import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hirang/app/sift_controller.dart';
import 'package:hirang/domain/review_state.dart';
import 'package:hirang/platform/sift_gateway.dart';

import 'support/fake_sift_gateway.dart';

void main() {
  test('verified trash remains terminal after clear, later operations, and JSON restart', () {
    final first = realPhoto('v1-row-1');
    final second = realPhoto('v1-row-2', mediaId: 2, generationAdded: 2);
    var state = ReviewState.initial().decide(first, ReviewDecision.mark);
    state = state.beginTrashOperation(
      operationId: 'first',
      nowMillis: 1,
      items: [first],
    );
    state = state.updateOperation(
      state.operation!.copyWith(
        status: 'complete',
        outcomes: {first.id: OperationItemOutcome.trashed},
      ),
    );
    expect(state.markedAssets(), isEmpty);
    expect(state.decisions.containsKey(first.id), isFalse);
    state = state.clearFinishedOperation();

    state = state.decide(second, ReviewDecision.mark);
    state = state.beginTrashOperation(
      operationId: 'second',
      nowMillis: 2,
      items: [second],
    );
    final restored = ReviewState.decode(state.encode());
    expect(restored.markedAssets().map((item) => item.id), [second.id]);
    expect(restored.terminalTrashedIds, contains(first.id));
    expect(restored.nextUnreviewed([first, second]), isNull);
    expect(restored.undoHistory, [second.id]);
  });

  test('reused MediaStore ids with a new insertion identity have a distinct decision key', () {
    final old = realPhoto(
      'volume/42/added-18',
      mediaId: 42,
      generationAdded: 18,
    );
    final replacement = realPhoto(
      'volume/42/added-19',
      mediaId: 42,
      generationAdded: 19,
    );
    final state = ReviewState.initial().decide(old, ReviewDecision.keep);
    expect(state.decisions.containsKey(replacement.id), isFalse);
    expect(state.nextUnreviewed([replacement])?.id, replacement.id);
  });

  test('operation locks prevent Undo and unmark until result is terminal', () {
    final photo = realPhoto('locked');
    var state = ReviewState.initial().decide(photo, ReviewDecision.mark);
    state = state.beginTrashOperation(
      operationId: 'lock',
      nowMillis: 1,
      items: [photo],
    );
    expect(() => state.undo(), throwsStateError);
    expect(() => state.unmark(photo.id), throwsStateError);
    expect(state.markedAssets(), [photo]);
  });

  test('demo marks stay out of the real library queue and filters preserve decisions', () {
    final demo = PhotoAsset(
      id: 'fiction-1',
      title: 'Fiction',
      demoIndex: 0,
      screenshotHeuristic: true,
    );
    final real = realPhoto('real-1');
    var state = ReviewState.initial()
        .withDemoMode(true)
        .decide(demo, ReviewDecision.mark);
    expect(state.markedAssets(), [demo]);
    expect(state.nextUnreviewed([real]), isNull);
    state = state.withFilters(const ReviewFilters(screenshotsOnly: true));
    expect(state.nextUnreviewed([demo]), isNull);
    expect(state.decisions[demo.id], ReviewDecision.mark);
  });

  test(
    'Undo is scoped to the active deck and preserves the other deck history',
    () {
      final demo = PhotoAsset(id: 'demo-undo', title: 'Demo', demoIndex: 1);
      final real = realPhoto('real-undo');
      var state = ReviewState.initial()
          .decide(real, ReviewDecision.keep)
          .withDemoMode(true)
          .decide(demo, ReviewDecision.mark);

      state = state.undo();
      expect(state.decisions.containsKey(demo.id), isFalse);
      expect(state.decisions[real.id], ReviewDecision.keep);
      expect(state.undoHistory, [real.id]);

      state = state.withDemoMode(false).undo();
      expect(state.decisions, isEmpty);
      expect(state.undoHistory, isEmpty);
    },
  );

  test('partially verified result removes only proven successes and keeps unresolved marked', () {
    final first = realPhoto('partial-a');
    final second = realPhoto('partial-b', mediaId: 2, generationAdded: 2);
    var state = ReviewState.initial()
        .decide(first, ReviewDecision.mark)
        .decide(second, ReviewDecision.mark);
    state = state.beginTrashOperation(
      operationId: 'partial',
      nowMillis: 1,
      items: [first, second],
    );
    state = state.updateOperation(
      state.operation!.copyWith(
        status: 'interrupted',
        outcomes: {
          first.id: OperationItemOutcome.trashed,
          second.id: OperationItemOutcome.unknown,
        },
      ),
    );
    expect(state.terminalTrashedIds, contains(first.id));
    expect(state.markedAssets().map((item) => item.id), [second.id]);
    expect(state.undoHistory, [second.id]);
  });

  test('an exact accessible restored identity returns to the review queue', () {
    final photo = realPhoto('already-trashed');
    final state = ReviewState.initial().copyWith(
      knownAssets: {photo.id: photo},
      terminalTrashedIds: {photo.id},
    );
    expect(state.nextUnreviewed([photo]), isNull);
    expect(state.filteredAssets([photo]), isEmpty);

    final restored = state.reconcileRestoredAssets([photo]);
    expect(restored.terminalTrashedIds, isEmpty);
    expect(restored.nextUnreviewed([photo])?.id, photo.id);
  });

  test(
    'restoration accepts an exact identity whose modified generation advanced',
    () {
      final original = realPhoto('modified-generation');
      final restored = PhotoAsset(
        id: original.id,
        title: original.title,
        uri: original.uri,
        volumeName: original.volumeName,
        mediaId: original.mediaId,
        generationAdded: original.generationAdded,
        generationModified: original.generationModified! + 17,
        volumeVersion: original.volumeVersion,
      );
      final state = ReviewState.initial().copyWith(
        knownAssets: {original.id: original},
        terminalTrashedIds: {original.id},
      );

      expect(
        state.reconcileRestoredAssets([restored]).terminalTrashedIds,
        isEmpty,
      );
    },
  );

  test(
    'absence and limited access never clear a confirmed-trash tombstone',
    () async {
      final photo = realPhoto('limited-restoration');
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'limited', sdkInt: 36)
        ..photos = const []
        ..saved = ReviewState.initial().copyWith(
          knownAssets: {photo.id: photo},
          terminalTrashedIds: {photo.id},
        );
      final controller = SiftController(gateway);

      await controller.initialize();
      expect(controller.state.terminalTrashedIds, contains(photo.id));
      expect(controller.state.decisions, isEmpty);

      gateway
        ..access = const PhotoAccess(status: 'denied', sdkInt: 36)
        ..photos = [photo];
      await controller.refreshFromSystem();
      expect(controller.state.terminalTrashedIds, contains(photo.id));

      gateway
        ..access = const PhotoAccess(status: 'limited', sdkInt: 36)
        ..photos = [photo];
      await controller.refreshFromSystem();
      expect(controller.state.terminalTrashedIds, isEmpty);
      expect(
        controller.state.nextUnreviewed(controller.visibleAssets)?.id,
        photo.id,
      );
    },
  );

  test(
    'query failure leaves tombstones and unrelated Keep decisions untouched',
    () async {
      final trashed = realPhoto('query-failure-trash');
      final kept = realPhoto(
        'query-failure-keep',
        mediaId: 2,
        generationAdded: 2,
      );
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..queryException = StateError('fixture query failure')
        ..saved = ReviewState.initial()
            .copyWith(
              knownAssets: {trashed.id: trashed, kept.id: kept},
              terminalTrashedIds: {trashed.id},
            )
            .decide(kept, ReviewDecision.keep);
      final controller = SiftController(gateway);

      await controller.initialize();
      expect(controller.state.terminalTrashedIds, contains(trashed.id));
      expect(controller.state.decisions[kept.id], ReviewDecision.keep);
    },
  );

  test('repeated refresh and restart preserve a restored decision with old journal', () async {
    final photo = realPhoto('controller-restoration');
    var saved = ReviewState.initial().decide(photo, ReviewDecision.mark);
    saved = saved.beginTrashOperation(
      operationId: 'retained-finished-journal',
      nowMillis: 1,
      items: [photo],
    );
    saved = saved.updateOperation(
      saved.operation!.copyWith(
        status: 'complete',
        outcomes: {photo.id: OperationItemOutcome.trashed},
      ),
    );
    final completed = saved.operation!;
    final gateway = FakeSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..photos = [photo]
      ..saved = saved
      ..operation = completed;

    final controller = SiftController(gateway);
    await controller.initialize();
    expect(controller.state.terminalTrashedIds, isEmpty);
    expect(await controller.decide(photo, ReviewDecision.keep), isTrue);
    await controller.refreshFromSystem();
    expect(controller.state.operation?.id, completed.id);
    expect(controller.state.terminalTrashedIds, isEmpty);
    expect(controller.state.decisions[photo.id], ReviewDecision.keep);

    final restarted = SiftController(gateway);
    await restarted.initialize();
    await restarted.refreshFromSystem();
    expect(restarted.state.operation?.id, completed.id);
    expect(restarted.state.terminalTrashedIds, isEmpty);
    expect(restarted.state.decisions[photo.id], ReviewDecision.keep);
  });

  test('restoration requires the same volume, item, version, and insertion identity', () {
    final original = realPhoto('stable-id');
    final state = ReviewState.initial().copyWith(
      knownAssets: {original.id: original},
      terminalTrashedIds: {original.id},
    );
    final replacementWithSameKey = PhotoAsset(
      id: original.id,
      title: original.title,
      uri: original.uri,
      volumeName: original.volumeName,
      mediaId: original.mediaId,
      generationAdded: original.generationAdded,
      generationModified: 2,
      volumeVersion: 'new-volume-version',
    );
    expect(
      state.reconcileRestoredAssets([
        replacementWithSameKey,
      ]).terminalTrashedIds,
      contains(original.id),
    );

    final reusedRow = realPhoto(
      'different-volume-item-identity',
      mediaId: original.mediaId!,
      generationAdded: original.generationAdded! + 1,
    );
    final afterReuse = state.reconcileRestoredAssets([reusedRow]);
    expect(afterReuse.terminalTrashedIds, contains(original.id));
    expect(afterReuse.nextUnreviewed([reusedRow])?.id, reusedRow.id);
    expect(afterReuse.decisions, isEmpty);
  });

  test('unknown operation outcomes keep old tombstones closed', () {
    final photo = realPhoto('unknown-restoration');
    final prior = TrashOperation(
      id: 'prior-success',
      createdAtMillis: 1,
      items: [photo],
      outcomes: {photo.id: OperationItemOutcome.trashed},
      status: 'complete',
    );
    var state = ReviewState.initial()
        .copyWith(knownAssets: {photo.id: photo})
        .updateOperation(prior);
    final newerUnknown = TrashOperation(
      id: 'new-uncertain-operation',
      createdAtMillis: 2,
      items: [photo],
      outcomes: {photo.id: OperationItemOutcome.unknown},
      status: 'interrupted',
    );
    state = state.updateOperation(newerUnknown);
    expect(
      state.reconcileRestoredAssets([photo]).terminalTrashedIds,
      contains(photo.id),
    );
  });

  test(
    'a pre-result query cannot infer restoration after a new trash success',
    () {
      final photo = realPhoto('query-race');
      final staleQueryEvents = <String, Set<String>>{};
      var state = ReviewState.initial().decide(photo, ReviewDecision.mark);
      state = state.beginTrashOperation(
        operationId: 'query-race-op',
        nowMillis: 1,
        items: [photo],
      );
      final completed = state.operation!.copyWith(
        status: 'complete',
        outcomes: {photo.id: OperationItemOutcome.trashed},
      );
      state = state.updateOperation(completed);

      expect(
        state.reconcileRestoredAssets([
          photo,
        ], appliedEventsAtSnapshot: staleQueryEvents).terminalTrashedIds,
        contains(photo.id),
      );
      expect(
        state.reconcileRestoredAssets(
          [photo],
          appliedEventsAtSnapshot: state.appliedTrashOutcomes,
        ).terminalTrashedIds,
        isEmpty,
      );
    },
  );

  test('legacy v1 state migrates without dropping terminal tombstones', () {
    final state = ReviewState.decode(
      '{"version":1,"demoMode":false,"filters":{},'
      '"decisions":{"kept":"keep"},'
      '"knownAssets":{},"terminalTrashedIds":["legacy"],'
      '"undoHistory":[],"operation":null}',
    );
    expect(state.terminalTrashedIds, {'legacy'});
    expect(state.decisions['kept'], ReviewDecision.keep);
    expect(state.appliedTrashOutcomes, isEmpty);
    expect(ReviewState.decode(state.encode()).terminalTrashedIds, {'legacy'});
  });

  test(
    'restoration survives decision, JSON restart, and old journal replay',
    () {
      final keepPhoto = realPhoto('restore-keep');
      final markPhoto = realPhoto(
        'restore-mark',
        mediaId: 2,
        generationAdded: 2,
      );

      ReviewState confirmed(PhotoAsset photo, String operationId) {
        var current = ReviewState.initial().decide(photo, ReviewDecision.mark);
        current = current.beginTrashOperation(
          operationId: operationId,
          nowMillis: 1,
          items: [photo],
        );
        return current.updateOperation(
          current.operation!.copyWith(
            status: 'complete',
            outcomes: {photo.id: OperationItemOutcome.trashed},
          ),
        );
      }

      final keptJournal = confirmed(keepPhoto, 'old-keep-op').operation!;
      var keepState = ReviewState.initial()
          .copyWith(knownAssets: {keepPhoto.id: keepPhoto})
          .updateOperation(keptJournal);
      keepState = keepState.reconcileRestoredAssets([keepPhoto]);
      keepState = keepState.decide(keepPhoto, ReviewDecision.keep);
      keepState = ReviewState.decode(keepState.encode())
          .updateOperation(keptJournal);
      expect(keepState.terminalTrashedIds, isEmpty);
      expect(keepState.decisions[keepPhoto.id], ReviewDecision.keep);

      final markedJournal = confirmed(markPhoto, 'old-mark-op').operation!;
      var markState = ReviewState.initial()
          .copyWith(knownAssets: {markPhoto.id: markPhoto})
          .updateOperation(markedJournal);
      markState = markState.reconcileRestoredAssets([markPhoto]);
      markState = markState.decide(markPhoto, ReviewDecision.mark);
      markState = ReviewState.decode(markState.encode())
          .updateOperation(markedJournal);
      expect(markState.terminalTrashedIds, isEmpty);
      expect(markState.decisions[markPhoto.id], ReviewDecision.mark);
      expect(markState.markedAssets().map((item) => item.id), [markPhoto.id]);

      markState = markState.beginTrashOperation(
        operationId: 'new-mark-op',
        nowMillis: 2,
        items: [markPhoto],
      );
      markState = markState.updateOperation(
        markState.operation!.copyWith(
          status: 'complete',
          outcomes: {markPhoto.id: OperationItemOutcome.trashed},
        ),
      );
      expect(markState.terminalTrashedIds, contains(markPhoto.id));
      expect(markState.decisions.containsKey(markPhoto.id), isFalse);
    },
  );

  test('cancelled system operation retains unresolved marks', () {
    final photo = realPhoto('cancelled');
    var state = ReviewState.initial().decide(photo, ReviewDecision.mark);
    state = state.beginTrashOperation(
      operationId: 'cancel',
      nowMillis: 1,
      items: [photo],
    );
    state = state.updateOperation(
      state.operation!.copyWith(
        status: 'cancelled',
        outcomes: {photo.id: OperationItemOutcome.cancelled},
      ),
    );
    expect(state.markedAssets(), [photo]);
    expect(state.terminalTrashedIds, isEmpty);
  });

  test('unmarking does not corrupt another persisted decision during filtered progress', () async {
    final gateway = FakeSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..photos = [
        realPhoto('a'),
        realPhoto('b', mediaId: 2, generationAdded: 2),
      ];
    final controller = SiftController(gateway);
    await controller.initialize();
    final a = gateway.photos.first;
    final b = gateway.photos.last;
    expect(await controller.decide(a, ReviewDecision.mark), isTrue);
    await controller.setFilters(const ReviewFilters(album: 'Fixture album'));
    expect(controller.state.reviewedCount(controller.visibleAssets), 1);
    await controller.unmark(a.id);
    expect(await controller.decide(b, ReviewDecision.keep), isTrue);
    final recovered = ReviewState.decode(gateway.saved.encode());
    expect(recovered.decisions[a.id], isNull);
    expect(recovered.decisions[b.id], ReviewDecision.keep);
    expect(recovered.filters.album, 'Fixture album');
  });

  test(
    'an awaiting Android prompt stays locked until the user confirms it closed',
    () async {
      final photo = realPhoto('awaiting');
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = [photo]
        ..operation = TrashOperation(
          id: 'awaiting-op',
          createdAtMillis: 1,
          items: [photo],
          outcomes: {photo.id: OperationItemOutcome.pending},
          status: 'awaitingSystemApproval',
        );
      final controller = SiftController(gateway);
      await controller.initialize();
      await controller.refreshOperation();
      expect(gateway.reconcileCalls, 0);
      expect(controller.state.operation!.status, 'awaitingSystemApproval');
      expect(controller.state.operation!.locks(photo.id), isTrue);

      await controller.refreshOperation(afterSystemScreenClosed: true);
      expect(gateway.reconcileCalls, 1);
      expect(gateway.lastReconcileAcknowledged, isTrue);
      expect(controller.state.operation!.status, 'interrupted');
      expect(controller.state.operation!.locks(photo.id), isFalse);
    },
  );

  test(
    'double begin calls reserve one native operation synchronously',
    () async {
      final photo = realPhoto('double-submit');
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = [photo]
        ..saved = ReviewState.initial().decide(photo, ReviewDecision.mark);
      final pendingNative = Completer<TrashOperation?>();
      gateway.beginCompleter = pendingNative;
      final controller = SiftController(gateway);
      await controller.initialize();

      final first = controller.beginTrash();
      final second = controller.beginTrash();
      await Future<void>.delayed(Duration.zero);
      expect(gateway.beginCalls, 1);
      final op = controller.state.operation!;
      pendingNative.complete(op.copyWith(status: 'awaitingSystemApproval'));
      await Future.wait([first, second]);
      expect(gateway.beginCalls, 1);
    },
  );

  test('late journal read cannot overwrite a newer trash operation', () async {
    final photo = realPhoto('fresh-operation');
    final olderPhoto = realPhoto('older-operation');
    final gateway = FakeSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..photos = [photo]
      ..saved = ReviewState.initial().decide(photo, ReviewDecision.mark);
    final controller = SiftController(gateway);
    await controller.initialize();

    final oldJournal = TrashOperation(
      id: 'stale-native-journal',
      createdAtMillis: 1,
      items: [olderPhoto],
      outcomes: {olderPhoto.id: OperationItemOutcome.unknown},
      status: 'interrupted',
    );
    final pendingRead = Completer<TrashOperation?>();
    gateway.readCompleter = pendingRead;
    final staleRefresh = controller.refreshOperation();

    await controller.beginTrash();
    final newId = controller.state.operation!.id;
    expect(controller.state.operation!.items.single.id, photo.id);

    pendingRead.complete(oldJournal);
    await staleRefresh;
    expect(controller.state.operation!.id, newId);
    expect(controller.state.operation!.items.single.id, photo.id);
  });

  test(
    'late journal read cannot resurrect a cleared finished operation',
    () async {
      final photo = realPhoto('clear-operation-race');
      final completed = TrashOperation(
        id: 'finished-operation',
        createdAtMillis: 1,
        items: [photo],
        outcomes: {photo.id: OperationItemOutcome.unknown},
        status: 'interrupted',
      );
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..operation = completed
        ..saved = ReviewState.initial().updateOperation(completed);
      final controller = SiftController(gateway);
      await controller.initialize();

      final pendingRead = Completer<TrashOperation?>();
      gateway.readCompleter = pendingRead;
      final staleRefresh = controller.refreshOperation();
      await controller.clearFinishedOperation();
      expect(controller.state.operation, isNull);

      pendingRead.complete(completed);
      await staleRefresh;
      expect(controller.state.operation, isNull);
    },
  );
}
