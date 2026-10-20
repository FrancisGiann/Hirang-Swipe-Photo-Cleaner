import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hirang/app/hirang_theme.dart';
import 'package:hirang/app/sift_controller.dart';
import 'package:hirang/domain/hirang_theme_id.dart';
import 'package:hirang/domain/review_state.dart';
import 'package:hirang/platform/sift_gateway.dart';
import 'package:hirang/ui/marked_review_screen.dart';
import 'package:hirang/ui/photo_tools_screen.dart';
import 'package:hirang/ui/sift_home.dart';

import 'support/fake_paged_sift_gateway.dart';
import 'support/fake_sift_gateway.dart';

void main() {
  test(
    'malformed optional cleanup state preserves version-one review fields',
    () {
      final photo = realPhoto('optional-session-migration');
      var state = ReviewState.initial()
          .copyWith(
            themeId: HirangThemeId.hatinggabi,
            filters: const ReviewFilters(
              monthKey: '2023-11',
              album: 'Fixture album',
              screenshotsOnly: true,
            ),
          )
          .decide(photo, ReviewDecision.mark)
          .beginTrashOperation(
            operationId: 'journal-keep',
            nowMillis: 10,
            items: [photo],
          );
      final json = Map<String, Object?>.from(jsonDecode(state.encode()) as Map)
        ..['cleanupSession'] = {'id': 'broken', 'items': 'not a list'}
        ..['cleanupPageCursor'] = 7;

      state = ReviewState.decode(jsonEncode(json));

      expect(state.decisions[photo.id], ReviewDecision.mark);
      expect(state.operation?.id, 'journal-keep');
      expect(state.themeId, HirangThemeId.hatinggabi);
      expect(state.filters.monthKey, '2023-11');
      expect(state.filters.album, 'Fixture album');
      expect(state.filters.screenshotsOnly, isTrue);
      expect(state.cleanupSession, isNull);
      expect(state.cleanupPageCursor, isNull);
    },
  );

  test('cleanup membership is immutable across decisions and restart', () {
    final first = realPhoto('snapshot-first');
    final second = realPhoto('snapshot-second', mediaId: 2, generationAdded: 2);
    var state = ReviewState.initial().startCleanupSession(
      sessionId: 'session-one',
      nowMillis: 10,
      kind: CleanupSessionKind.photos,
      items: [first, second],
      nextCursor: 'next-page',
      cursorScope: 'recent|null|false',
    );
    expect(
      () => state.startCleanupSession(
        sessionId: 'replacement',
        nowMillis: 11,
        kind: CleanupSessionKind.photos,
        items: [realPhoto('replacement-photo')],
        nextCursor: null,
        cursorScope: 'recent|null|false',
      ),
      throwsStateError,
    );

    state = state.decide(first, ReviewDecision.keep).updateCleanupAvailability(
      'session-one',
      {
        first.id: CleanupAvailability.unconfirmed,
        second.id: CleanupAvailability.unconfirmed,
      },
    );
    final restored = ReviewState.decode(state.encode());
    expect(restored.cleanupSession?.items.map((item) => item.id), [
      first.id,
      second.id,
    ]);
    expect(
      restored.cleanupSession?.availability[first.id],
      CleanupAvailability.unconfirmed,
    );
    expect(restored.decisions[first.id], ReviewDecision.keep);
    expect(
      restored.cleanupSession!.items
          .where((item) => restored.decisions.containsKey(item.id))
          .length,
      1,
    );

    state = restored
        .finishCleanupSession('session-one', 12)
        .startCleanupSession(
          sessionId: 'session-two',
          nowMillis: 13,
          kind: CleanupSessionKind.photos,
          items: [
            realPhoto('next-batch-photo', mediaId: 3, generationAdded: 3),
          ],
          nextCursor: null,
          cursorScope: 'recent|null|false',
        );
    expect(state.cleanupSession?.id, 'session-two');
    expect(state.cleanupPageCursor, isNull);
    expect(state.cleanupCursorScope, isNull);
  });

  test('mixed photo pages are filtered to the requested tool mode', () {
    final camera = realPhoto('camera-photo', mediaId: 1);
    final screenshot = PhotoAsset(
      id: 'screenshot-photo',
      title: 'Screenshot',
      uri: 'content://media/external_primary/images/media/2',
      volumeName: 'external_primary',
      mediaId: 2,
      generationAdded: 2,
      volumeVersion: 'fixture-catalog-v1',
      sizeBytes: 512,
      screenshotHeuristic: true,
    );
    final unknown = PhotoAsset(
      id: 'unknown-size',
      title: 'Unknown',
      sizeBytes: 0,
    );
    final mixedPage = [camera, screenshot, unknown];

    expect(
      mixedPage
          .where(
            (item) =>
                photoMatchesQueryMode(PhotoQueryMode.screenshotHints, item),
          )
          .map((item) => item.id),
      ['screenshot-photo'],
    );
    expect(
      mixedPage
          .where(
            (item) => photoMatchesQueryMode(PhotoQueryMode.largestKnown, item),
          )
          .map((item) => item.id),
      ['camera-photo', 'screenshot-photo'],
    );
    expect(
      mixedPage
          .where(
            (item) => photoMatchesQueryMode(PhotoQueryMode.unknownSize, item),
          )
          .map((item) => item.id),
      ['unknown-size'],
    );
  });

  test('size modes distinguish null, zero, negative and positive values', () {
    final cases = <int?, bool>{null: true, 0: true, -1: true, 2048: false};
    for (final entry in cases.entries) {
      final item = PhotoAsset(
        id: 'size-${entry.key}',
        title: 'Size fixture',
        sizeBytes: entry.key,
      );
      expect(
        photoMatchesQueryMode(PhotoQueryMode.unknownSize, item),
        entry.value,
        reason: 'sizeBytes=${entry.key}',
      );
      expect(
        photoMatchesQueryMode(PhotoQueryMode.largestKnown, item),
        !entry.value,
        reason: 'sizeBytes=${entry.key}',
      );
    }
  });

  testWidgets(
    'marked null and nonpositive sizes stay unknown and do not affect estimates',
    (tester) async {
      final sizes = <int?>[null, 0, -1, 2048];
      final photos = [
        for (var index = 0; index < sizes.length; index++)
          PhotoAsset(
            id: 'marked-size-$index',
            title: 'Marked size $index',
            uri: 'content://media/external_primary/images/media/${index + 1}',
            volumeName: 'external_primary',
            mediaId: index + 1,
            generationAdded: index + 1,
            generationModified: 1,
            volumeVersion: 'fixture-catalog-v1',
            album: 'Fixture album',
            sizeBytes: sizes[index],
          ),
      ];
      var saved = ReviewState.initial();
      for (final photo in photos) {
        saved = saved.decide(photo, ReviewDecision.mark);
      }
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = photos
        ..saved = saved;
      final controller = SiftController(gateway);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(home: MarkedReviewScreen(controller: controller)),
      );
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(
        find.textContaining('2 KB estimated selected size · 3 size unknown'),
        findsOneWidget,
      );
      expect(find.textContaining('Size unknown'), findsNWidgets(3));
      expect(find.textContaining('0 KB'), findsNothing);
      expect(find.textContaining('-1'), findsNothing);
    },
  );

  testWidgets('unknown-size tool skips known-size rows in a mixed page', (
    tester,
  ) async {
    final known = realPhoto('known-size-camera');
    final unknown = PhotoAsset(
      id: 'unknown-size-result',
      title: 'Unknown size',
    );
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..pageLoader = (request) => PhotoPage(
        items: request.mode == PhotoQueryMode.unknownSize
            ? [known, unknown]
            : const [],
        status: 'ready',
      );
    final controller = SiftController(gateway);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: PhotoToolsScreen(
          controller: controller,
          initialMode: PhotoQueryMode.unknownSize,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(known.title), findsNothing);
    expect(find.text(unknown.title), findsWidgets);
    expect(
      find.textContaining('Some returned rows did not match'),
      findsOneWidget,
    );
  });

  testWidgets('screenshot tool never shows camera rows from a mixed page', (
    tester,
  ) async {
    final camera = realPhoto('ordinary-camera-photo');
    final screenshot = PhotoAsset(
      id: 'hinted-screenshot',
      title: 'Hinted screenshot',
      sizeBytes: 4096,
      screenshotHeuristic: true,
      relativePath: 'Pictures/Screenshots/',
    );
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..pageLoader = (request) => PhotoPage(
        items: request.mode == PhotoQueryMode.screenshotHints
            ? [camera, screenshot]
            : const [],
        status: 'ready',
      );
    final controller = SiftController(gateway);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: PhotoToolsScreen(
          controller: controller,
          initialMode: PhotoQueryMode.screenshotHints,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(camera.title), findsNothing);
    expect(find.text(screenshot.title), findsWidgets);
    expect(
      find.textContaining('Some returned rows did not match'),
      findsOneWidget,
    );
  });

  testWidgets('Home can continue from reviewed first page to later photos', (
    tester,
  ) async {
    final firstPage = List.generate(
      60,
      (index) => realPhoto(
        'reviewed-home-$index',
        mediaId: index + 1,
        generationAdded: index + 1,
      ),
    );
    final laterPhoto = realPhoto(
      'later-home-photo',
      mediaId: 61,
      generationAdded: 61,
    );
    var saved = ReviewState.initial().copyWith(onboardingComplete: true);
    for (final item in firstPage) {
      saved = saved.decide(item, ReviewDecision.keep);
    }
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..saved = saved
      ..pageLoader = (request) => request.cursor == null
          ? PhotoPage(
              items: firstPage,
              status: 'ready',
              cursor: 'later-page',
              hasMore: true,
            )
          : PhotoPage(items: [laterPhoto], status: 'ready');
    final controller = SiftController(gateway);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHirangThemeFor(HirangThemeId.amihan),
        home: SiftHome(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    final nextPageButton = find.byKey(const Key('loadNextPhotoPageButton'));
    expect(nextPageButton, findsOneWidget);
    await tester.ensureVisible(nextPageButton);
    await tester.tap(nextPageButton);
    await tester.pumpAndSettle();

    expect(find.text(laterPhoto.title), findsWidgets);
    expect(controller.hasMorePhotos, isFalse);
  });

  test('cleanup batches continue across native pages and resume the frozen next batch', () async {
    final firstPage = List.generate(
      20,
      (index) => realPhoto(
        'batch-one-$index',
        mediaId: index + 1,
        generationAdded: index + 1,
      ),
    );
    final secondPage = List.generate(
      20,
      (index) => realPhoto(
        'batch-two-$index',
        mediaId: index + 21,
        generationAdded: index + 21,
      ),
    );
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..pageLoader = (request) {
        if (request.pageSize == 60) {
          return const PhotoPage(items: [], status: 'ready');
        }
        if (request.cursor == null) {
          return PhotoPage(
            items: firstPage,
            status: 'ready',
            cursor: 'page-two',
            hasMore: true,
          );
        }
        if (request.cursor == 'page-two') {
          return PhotoPage(items: secondPage, status: 'ready');
        }
        return const PhotoPage(items: [], status: 'stale');
      };
    final controller = SiftController(gateway);

    await controller.initialize();
    expect(
      await controller.startCleanupSession(kind: CleanupSessionKind.photos),
      isTrue,
    );
    expect(
      controller.state.cleanupSession?.items.map((item) => item.id),
      firstPage.map((item) => item.id),
    );
    for (final item in firstPage) {
      expect(await controller.decide(item, ReviewDecision.keep), isTrue);
    }
    await controller.finishCleanupSession();

    expect(controller.state.cleanupPageCursor, 'page-two');
    expect(
      await controller.startCleanupSession(kind: CleanupSessionKind.photos),
      isTrue,
    );
    expect(
      controller.state.cleanupSession?.items.map((item) => item.id),
      secondPage.map((item) => item.id),
    );

    final restarted = SiftController(gateway);
    await restarted.initialize();
    expect(restarted.state.cleanupSession?.isActive, isTrue);
    expect(
      restarted.state.cleanupSession?.items.map((item) => item.id),
      secondPage.map((item) => item.id),
    );
    expect(restarted.state.decisions.length, 20);
  });

  test('failed session save leaves the deck and decisions unchanged', () async {
    final photo = realPhoto('failed-session-save');
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..pageLoader = (request) => PhotoPage(
        items: request.pageSize == 20 ? [photo] : const [],
        status: 'ready',
      );
    final controller = SiftController(gateway);
    await controller.initialize();
    gateway.saveException = StateError('fixture save failure');

    expect(
      await controller.startCleanupSession(kind: CleanupSessionKind.photos),
      isFalse,
    );
    expect(controller.state.cleanupSession, isNull);
    expect(controller.state.decisions, isEmpty);
  });

  test('session start discards a delayed page after catalog refresh', () async {
    final photo = realPhoto('stale-session-page');
    final delayedPage = Completer<PhotoPage>();
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'limited', sdkInt: 36)
      ..pageLoader = (request) => request.pageSize == 20
          ? delayedPage.future
          : const PhotoPage(items: [], status: 'ready');
    final controller = SiftController(gateway);
    await controller.initialize();

    final starting = controller.startCleanupSession(
      kind: CleanupSessionKind.photos,
    );
    await Future<void>.delayed(Duration.zero);
    await controller.refreshFromSystem();
    delayedPage.complete(PhotoPage(items: [photo], status: 'ready'));

    expect(await starting, isFalse);
    expect(controller.state.cleanupSession, isNull);
  });

  test('page-two exact restored identity clears only its confirmed trash tombstone', () async {
    final restoredPhoto = realPhoto(
      'restore-after-first-page',
      mediaId: 81,
      generationAdded: 81,
    );
    final firstPage = List.generate(
      60,
      (index) => realPhoto(
        'home-first-$index',
        mediaId: index + 1,
        generationAdded: index + 1,
      ),
    );
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..saved = ReviewState.initial().copyWith(
        knownAssets: {restoredPhoto.id: restoredPhoto},
        terminalTrashedIds: {restoredPhoto.id},
      )
      ..pageLoader = (request) => request.cursor == null
          ? PhotoPage(
              items: firstPage,
              status: 'ready',
              cursor: 'page-two',
              hasMore: true,
            )
          : PhotoPage(items: [restoredPhoto], status: 'ready');
    final controller = SiftController(gateway);

    await controller.initialize();
    expect(controller.state.terminalTrashedIds, contains(restoredPhoto.id));
    await controller.loadMorePhotos();

    expect(
      controller.state.terminalTrashedIds,
      isNot(contains(restoredPhoto.id)),
    );
    expect(
      controller.assets.any((item) => item.id == restoredPhoto.id),
      isTrue,
    );
  });

  test(
    'tool page reconciliation requires current catalog and exact identity',
    () async {
      final photo = realPhoto('tool-page-restore');
      final gateway = FakePagedSiftGateway()
        ..access = const PhotoAccess(status: 'limited', sdkInt: 36)
        ..saved = ReviewState.initial().copyWith(
          knownAssets: {photo.id: photo},
          terminalTrashedIds: {photo.id},
        )
        ..pageLoader = (_) => const PhotoPage(items: [], status: 'ready');
      final controller = SiftController(gateway);
      await controller.initialize();
      final events = controller.appliedTrashOutcomesSnapshot();
      final catalogRevision = controller.photoCatalogRevision;

      await controller.refreshFromSystem();
      expect(controller.access.status, 'limited');
      expect(controller.photoCatalogRevision, greaterThan(catalogRevision));
      await controller.reconcileToolPage(
        items: [photo],
        appliedEventsAtSnapshot: events,
        expectedCatalogRevision: catalogRevision,
        expectedAccess: 'limited',
      );

      expect(controller.state.terminalTrashedIds, contains(photo.id));
    },
  );

  test('failed session revalidation marks pending items unconfirmed without losing decisions', () async {
    final pending = realPhoto('session-pending');
    final kept = realPhoto('session-kept', mediaId: 2, generationAdded: 2);
    final saved = ReviewState.initial()
        .startCleanupSession(
          sessionId: 'session-failure',
          nowMillis: 1,
          kind: CleanupSessionKind.photos,
          items: [pending, kept],
          nextCursor: null,
          cursorScope: 'recent|null|false',
        )
        .decide(kept, ReviewDecision.keep);
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..saved = saved
      ..pageLoader = (_) => const PhotoPage(items: [], status: 'ready');
    gateway.revalidationCompleter = Completer<List<Revalidation>>();
    final controller = SiftController(gateway);

    final initialization = controller.initialize();
    while (gateway.revalidatedIds.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    gateway.revalidationCompleter!.completeError(StateError('inaccessible'));
    await initialization;

    expect(
      controller.state.cleanupSession?.availability[pending.id],
      CleanupAvailability.unconfirmed,
    );
    expect(controller.cleanupItemConfirmed(pending.id), isFalse);
    expect(controller.state.decisions[kept.id], ReviewDecision.keep);
    expect(
      controller.state.cleanupSession?.availability[kept.id],
      CleanupAvailability.available,
    );
  });

  test('denied access does not trust saved session availability', () async {
    final photo = realPhoto('denied-session-item');
    final gateway = FakePagedSiftGateway()
      ..access = const PhotoAccess(status: 'denied', sdkInt: 36)
      ..saved = ReviewState.initial().startCleanupSession(
        sessionId: 'denied-session',
        nowMillis: 1,
        kind: CleanupSessionKind.photos,
        items: [photo],
        nextCursor: null,
        cursorScope: 'recent|null|false',
      )
      ..pageLoader = (_) => const PhotoPage(items: [], status: 'denied');
    final controller = SiftController(gateway);

    await controller.initialize();

    expect(
      controller.state.cleanupSession?.availability[photo.id],
      CleanupAvailability.unconfirmed,
    );
    expect(controller.cleanupItemConfirmed(photo.id), isFalse);
  });
}
