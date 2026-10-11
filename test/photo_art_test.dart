import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hirang/app/sift_controller.dart';
import 'package:hirang/app/hirang_theme.dart';
import 'package:hirang/domain/hirang_theme_id.dart';
import 'package:hirang/domain/review_state.dart';
import 'package:hirang/platform/sift_gateway.dart';
import 'package:hirang/ui/photo_art.dart';
import 'package:hirang/ui/sift_home.dart';

import 'support/fake_sift_gateway.dart';

void main() {
  late Uint8List fixture;
  late Uint8List previewFixture;

  setUpAll(() {
    fixture = File('test/fixtures/detail_generated.png').readAsBytesSync();
    previewFixture = File('test/fixtures/market_generated.png')
        .readAsBytesSync();
  });

  setUp(PhotoArtwork.invalidateAll);

  testWidgets('photo request key separates rendered size and gateway', (
    tester,
  ) async {
    final firstGateway = FakeSiftGateway()..thumbnailData = fixture;
    final photo = realPhoto('size-key-photo');
    Widget art(FakeSiftGateway gateway, int edge) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 220,
          height: 320,
          child: PhotoArtwork(
            item: photo,
            demoMode: false,
            gateway: gateway,
            maxEdge: edge,
            preferSourceDetail: true,
          ),
        ),
      ),
    );

    await tester.pumpWidget(art(firstGateway, 512));
    await _settlePhotoImages(tester, fixture);
    expect(
      firstGateway.imageRequests
          .map((request) => (request.maxEdge, request.preferSourceDetail))
          .toSet(),
      {(512, false), (512, true)},
    );

    await tester.pumpWidget(art(firstGateway, 1024));
    await _settlePhotoImages(tester, fixture);
    expect(
      firstGateway.imageRequests
          .map((request) => (request.maxEdge, request.preferSourceDetail))
          .toSet(),
      {(512, false), (512, true), (1024, true)},
    );

    final secondGateway = FakeSiftGateway()..thumbnailData = fixture;
    await tester.pumpWidget(art(secondGateway, 1024));
    await _settlePhotoImages(tester, fixture);
    expect(secondGateway.imageRequests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'SiftHome prefetches measured detail for next eligible photo and warms cache',
    (tester) async {
      final current = realPhoto('prefetch-current');
      final reviewed = realPhoto(
        'prefetch-reviewed',
        mediaId: 2,
        generationAdded: 2,
      );
      final next = realPhoto('prefetch-next', mediaId: 3, generationAdded: 3);
      final afterNext = realPhoto(
        'prefetch-after-next',
        mediaId: 4,
        generationAdded: 4,
      );
      final beyondLookahead = realPhoto(
        'prefetch-beyond',
        mediaId: 5,
        generationAdded: 5,
      );
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = [current, reviewed, next, afterNext, beyondLookahead]
        ..thumbnailData = fixture
        ..saved = ReviewState.initial()
            .decide(reviewed, ReviewDecision.keep)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangThemeFor(HirangThemeId.amihan),
          home: SiftHome(controller: controller),
        ),
      );
      await tester.pump();
      await _settlePhotoImages(tester, fixture);
      await tester.pumpAndSettle();

      final cardSize = tester.getSize(
        find.byKey(const Key('swipeCardGesture')),
      );
      final physicalEdge =
          (cardSize.width > cardSize.height
              ? cardSize.width
              : cardSize.height) *
          tester.view.devicePixelRatio;
      final measuredEdge = (((physicalEdge / 64).ceil()) * 64)
          .clamp(512, 2048)
          .toInt();
      expect(controller.current?.id, current.id);
      expect(
        gateway.imageRequests.take(2).map((request) => request.key).toSet(),
        {'${current.id}|512|false', '${current.id}|$measuredEdge|true'},
      );
      expect(
        gateway.imageRequests.where((request) => request.id == reviewed.id),
        isEmpty,
      );
      expect(
        gateway.imageRequests.where(
          (request) => request.id == beyondLookahead.id,
        ),
        isEmpty,
      );
      expect(
        gateway.imageRequests
            .where((request) => request.id == next.id)
            .map((request) => (request.maxEdge, request.preferSourceDetail))
            .toSet(),
        {(measuredEdge, true), (512, false)},
      );
      expect(
        gateway.imageRequests
            .where((request) => request.id == afterNext.id)
            .map((request) => (request.maxEdge, request.preferSourceDetail))
            .toSet(),
        {(512, false)},
      );
      final requestCount = gateway.imageRequests.length;
      int requestsFor(String id) =>
          gateway.imageRequests.where((request) => request.id == id).length;
      final currentRequests = requestsFor(current.id);
      final nextRequests = requestsFor(next.id);

      await tester.tap(find.byKey(const Key('keepButton')));
      await tester.pumpAndSettle();
      expect(controller.current?.id, next.id);
      expect(requestsFor(next.id), nextRequests);

      await tester.tap(find.byKey(const Key('undoButton')));
      await tester.pumpAndSettle();
      expect(controller.current?.id, current.id);
      expect(requestsFor(current.id), currentRequests);
      expect(gateway.imageRequests.length, greaterThanOrEqualTo(requestCount));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'speculative entries reclaim stale LRU slots while preserving the visible card',
    (tester) async {
      final photos = List.generate(
        9,
        (index) => realPhoto(
          'bounded-cache-$index',
          mediaId: index + 1,
          generationAdded: index + 1,
        ),
      );
      final gateway = FakeSiftGateway()
        ..thumbnailData = fixture
        ..thumbnailWidth = 1800
        ..thumbnailHeight = 2700;

      Future<void> show(PhotoAsset photo) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 300,
              height: 420,
              child: PhotoArtwork(
                key: ValueKey(photo.id),
                item: photo,
                demoMode: false,
                gateway: gateway,
                maxEdge: 1280,
                preferSourceDetail: true,
              ),
            ),
          ),
        );
        await _settlePhotoImages(tester, fixture);
        await tester.pumpAndSettle();
      }

      for (final photo in photos.take(6)) {
        await show(photo);
      }
      expect(gateway.imageRequests, hasLength(12));
      final beforePrefetch = gateway.imageRequests.length;

      PhotoArtwork.prefetch(
        gateway,
        current: photos[5],
        detailMaxEdge: 1280,
        upcoming: photos.skip(6).take(3),
      );
      await tester.pump();
      for (var index = 0; index < 8; index++) {
        await tester.pump(const Duration(milliseconds: 80));
      }

      final afterPrefetch = gateway.imageRequests.length;
      expect(afterPrefetch, greaterThan(beforePrefetch));
      expect(
        gateway.imageRequests
            .where((request) => request.id == photos[6].id)
            .map((request) => (request.maxEdge, request.preferSourceDetail))
            .toSet(),
        {(1280, true), (512, false)},
      );
      await show(photos[5]);
      expect(gateway.imageRequests, hasLength(afterPrefetch));

      await show(photos[6]);
      expect(
        gateway.imageRequests.map((request) => request.key).toList(),
        hasLength(afterPrefetch),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('covering review cancels queued photo lookahead', (tester) async {
    final current = realPhoto('route-current');
    final next = realPhoto('route-next', mediaId: 2, generationAdded: 2);
    final afterNext = realPhoto(
      'route-after-next',
      mediaId: 3,
      generationAdded: 3,
    );
    final preview = Completer<PhotoImageData?>();
    final detail = Completer<PhotoImageData?>();
    final gateway = FakeSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..photos = [current, next, afterNext]
      ..thumbnailData = fixture
      ..imageCompletersByRequest['${current.id}|512|false'] = preview
      ..imageCompletersByRequest['${current.id}|2048|true'] = detail
      ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
    final controller = SiftController(gateway);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHirangThemeFor(HirangThemeId.amihan),
        navigatorObservers: [photoRouteObserver],
        home: SiftHome(controller: controller),
      ),
    );
    await tester.pump();
    expect(
      gateway.imageRequests.where((request) => request.id == current.id),
      hasLength(2),
    );

    final navigator = Navigator.of(
      tester.element(find.byKey(const Key('swipeCardGesture'))),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering route')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    preview.complete(
      PhotoImageData(
        bytes: previewFixture,
        width: 720,
        height: 900,
        isSourceDetail: false,
      ),
    );
    detail.complete(
      PhotoImageData(
        bytes: fixture,
        width: 1800,
        height: 2700,
        isSourceDetail: true,
      ),
    );
    await tester.pump();
    await _settlePhotoImages(tester, fixture);
    await tester.pump();

    expect(
      gateway.imageRequests.where(
        (request) => request.id == next.id || request.id == afterNext.id,
      ),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'speculative thumbnail is skipped before evicting its desired source detail',
    (tester) async {
      final current = realPhoto('byte-pressure-current');
      final next = realPhoto(
        'byte-pressure-next',
        mediaId: 2,
        generationAdded: 2,
      );
      final afterNext = realPhoto(
        'byte-pressure-after-next',
        mediaId: 3,
        generationAdded: 3,
      );
      final visibleBytes = _padEncodedPng(fixture, 4 * 1024 * 1024);
      final detailBytes = _padEncodedPng(fixture, 12 * 1024 * 1024);
      final gateway = FakeSiftGateway()
        ..photoImageLoader = (item, edge, sourceDetail) async {
          final bytes = item.id == current.id
              ? visibleBytes
              : item.id == next.id && sourceDetail
              ? detailBytes
              : fixture;
          return PhotoImageData(
            bytes: bytes,
            width: edge,
            height: (edge * 1.5).round(),
            isSourceDetail: sourceDetail,
          );
        };

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 420,
            child: PhotoArtwork(
              item: current,
              demoMode: false,
              gateway: gateway,
              maxEdge: 512,
              preferSourceDetail: false,
            ),
          ),
        ),
      );
      await _settlePhotoImages(tester, visibleBytes);
      await tester.pumpAndSettle();

      PhotoArtwork.prefetch(
        gateway,
        current: current,
        detailMaxEdge: 1280,
        upcoming: [next, afterNext],
      );
      for (var index = 0; index < 8; index++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(
        gateway.imageRequests.where(
          (request) => request.id == next.id && request.preferSourceDetail,
        ),
        hasLength(1),
      );
      expect(
        gateway.imageRequests.where(
          (request) => request.id == next.id && !request.preferSourceDetail,
        ),
        hasLength(1),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 420,
            child: PhotoArtwork(
              key: ValueKey(next.id),
              item: next,
              demoMode: false,
              gateway: gateway,
              maxEdge: 1280,
              preferSourceDetail: true,
            ),
          ),
        ),
      );
      await _settlePhotoImages(tester, fixture);
      await tester.pumpAndSettle();
      expect(
        gateway.imageRequests.where(
          (request) => request.id == next.id && request.preferSourceDetail,
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new identity stays in loading state and never shows prior photo',
    (tester) async {
      final oldPhoto = realPhoto('old-photo');
      final newPhoto = realPhoto('new-photo', mediaId: 2, generationAdded: 2);
      final oldPending = Completer<PhotoImageData?>();
      final newPending = Completer<PhotoImageData?>();
      final gateway = FakeSiftGateway()
        ..imageCompletersById[oldPhoto.id] = oldPending
        ..imageCompletersById[newPhoto.id] = newPending;

      Widget art(PhotoAsset item) => MaterialApp(
        home: SizedBox(
          width: 300,
          height: 420,
          child: PhotoArtwork(
            item: item,
            demoMode: false,
            gateway: gateway,
            maxEdge: 1280,
            preferSourceDetail: true,
          ),
        ),
      );

      await tester.pumpWidget(art(oldPhoto));
      await tester.pump();
      await tester.pumpWidget(art(newPhoto));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      oldPending.complete(
        PhotoImageData(
          bytes: fixture,
          width: 1800,
          height: 2700,
          isSourceDetail: true,
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      newPending.complete(
        PhotoImageData(
          bytes: fixture,
          width: 1800,
          height: 2700,
          isSourceDetail: true,
        ),
      );
      await _settlePhotoImages(tester, fixture);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview-first and detail-first completion swap only after the detail frame',
    (tester) async {
      final previewFirst = realPhoto('preview-first');
      final detailFirst = realPhoto(
        'detail-first',
        mediaId: 2,
        generationAdded: 2,
      );
      final previewBeforeDetail = Completer<PhotoImageData?>();
      final detailAfterPreview = Completer<PhotoImageData?>();
      final previewAfterDetail = Completer<PhotoImageData?>();
      final detailBeforePreview = Completer<PhotoImageData?>();
      final gateway = FakeSiftGateway()
        ..imageCompletersByRequest['${previewFirst.id}|512|false'] =
            previewBeforeDetail
        ..imageCompletersByRequest['${previewFirst.id}|1280|true'] =
            detailAfterPreview
        ..imageCompletersByRequest['${detailFirst.id}|512|false'] =
            previewAfterDetail
        ..imageCompletersByRequest['${detailFirst.id}|1280|true'] =
            detailBeforePreview;

      Widget art(PhotoAsset item) => MaterialApp(
        home: SizedBox(
          width: 300,
          height: 420,
          child: PhotoArtwork(
            key: ValueKey(item.id),
            item: item,
            demoMode: false,
            gateway: gateway,
            maxEdge: 1280,
            preferSourceDetail: true,
          ),
        ),
      );

      await tester.pumpWidget(art(previewFirst));
      await tester.pump();
      previewBeforeDetail.complete(
        PhotoImageData(
          bytes: previewFixture,
          width: 720,
          height: 900,
          isSourceDetail: false,
        ),
      );
      await tester.pump();
      await _settlePhotoImages(tester, previewFixture);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      detailAfterPreview.complete(
        PhotoImageData(
          bytes: fixture,
          width: 1800,
          height: 2700,
          isSourceDetail: true,
        ),
      );
      await tester.pump();
      await _settlePhotoImages(tester, fixture);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pumpWidget(art(detailFirst));
      await tester.pump();
      detailBeforePreview.complete(
        PhotoImageData(
          bytes: fixture,
          width: 1800,
          height: 2700,
          isSourceDetail: true,
        ),
      );
      await tester.pump();
      await _settlePhotoImages(tester, fixture);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      previewAfterDetail.complete(
        PhotoImageData(
          bytes: previewFixture,
          width: 720,
          height: 900,
          isSourceDetail: false,
        ),
      );
      await tester.pump();
      await _settlePhotoImages(tester, previewFixture);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail request failure retains preview and exposes Retry', (
    tester,
  ) async {
    final photo = realPhoto('failed-detail');
    final preview = Completer<PhotoImageData?>();
    final detail = Completer<PhotoImageData?>();
    final gateway = FakeSiftGateway()
      ..imageCompletersByRequest['${photo.id}|512|false'] = preview
      ..imageCompletersByRequest['${photo.id}|1280|true'] = detail;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 420,
          child: PhotoArtwork(
            item: photo,
            demoMode: false,
            gateway: gateway,
            maxEdge: 1280,
            preferSourceDetail: true,
          ),
        ),
      ),
    );
    await tester.pump();
    preview.complete(
      PhotoImageData(
        bytes: previewFixture,
        width: 720,
        height: 900,
        isSourceDetail: false,
      ),
    );
    await tester.pump();
    await _settlePhotoImages(tester, previewFixture);
    expect(find.byType(Image), findsOneWidget);

    detail.completeError(StateError('fixture source decode failure'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Retry detail'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail decode failure keeps preview and offers a retry', (
    tester,
  ) async {
    final photo = realPhoto('malformed-detail');
    final malformedBytes = Uint8List.fromList([0, 1, 2, 3]);
    final gateway = FakeSiftGateway()
      ..photoImageLoader = (_, edge, sourceDetail) async => PhotoImageData(
        bytes: sourceDetail ? malformedBytes : previewFixture,
        width: edge,
        height: (edge * 1.5).round(),
        isSourceDetail: sourceDetail,
      );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 420,
          child: PhotoArtwork(
            item: photo,
            demoMode: false,
            gateway: gateway,
            maxEdge: 1280,
            preferSourceDetail: true,
          ),
        ),
      ),
    );
    await _settleRenderedPhotoFrames(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Preview only'), findsOneWidget);
    expect(find.byTooltip('Retry higher-detail photo'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mounted image reloads after same-identity cache invalidation', (
    tester,
  ) async {
    final photo = realPhoto('reselected-photo');
    final refreshed = Completer<PhotoImageData?>();
    final gateway = FakeSiftGateway()..thumbnailData = fixture;
    Widget art() => MaterialApp(
      home: SizedBox(
        width: 300,
        height: 420,
        child: PhotoArtwork(
          item: photo,
          demoMode: false,
          gateway: gateway,
          maxEdge: 1280,
          preferSourceDetail: true,
        ),
      ),
    );

    await tester.pumpWidget(art());
    await _settlePhotoImages(tester, fixture);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    gateway.imageCompletersById[photo.id] = refreshed;
    PhotoArtwork.invalidateAll();
    await tester.pump();
    expect(gateway.imageRequests, hasLength(4));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    refreshed.complete(
      PhotoImageData(
        bytes: fixture,
        width: 1800,
        height: 2700,
        isSourceDetail: true,
      ),
    );
    await _settlePhotoImages(tester, fixture);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-key replacement waits for invalidated native request', (
    tester,
  ) async {
    final photo = realPhoto('invalidated-in-flight');
    final first = Completer<PhotoImageData?>();
    final replacement = Completer<PhotoImageData?>();
    var attempts = 0;
    final gateway = FakeSiftGateway()
      ..photoImageLoader = (_, _, _) =>
          attempts++ == 0 ? first.future : replacement.future;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 260,
          height: 360,
          child: PhotoArtwork(
            item: photo,
            demoMode: false,
            gateway: gateway,
            maxEdge: 512,
            preferSourceDetail: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(gateway.imageRequests, hasLength(1));

    PhotoArtwork.invalidate(photo);
    await tester.pump();
    expect(gateway.imageRequests, hasLength(1));

    first.complete(
      PhotoImageData(
        bytes: fixture,
        width: 1800,
        height: 2700,
        isSourceDetail: false,
      ),
    );
    await tester.pump();
    expect(gateway.imageRequests, hasLength(2));

    replacement.complete(
      PhotoImageData(
        bytes: fixture,
        width: 1800,
        height: 2700,
        isSourceDetail: false,
      ),
    );
    await _settlePhotoImages(tester, fixture);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(gateway.maxActiveImageRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('latest foreground request waits in one bounded slot', (
    tester,
  ) async {
    final photos = List.generate(
      4,
      (index) => realPhoto(
        'queue-photo-$index',
        mediaId: index + 1,
        generationAdded: index + 1,
      ),
    );
    final pending = {
      for (final photo in photos) photo.id: Completer<PhotoImageData?>(),
    };
    final gateway = FakeSiftGateway()..imageCompletersById.addAll(pending);

    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          children: [
            for (final photo in photos)
              SizedBox(
                width: 100,
                height: 140,
                child: PhotoArtwork(
                  item: photo,
                  demoMode: false,
                  gateway: gateway,
                  maxEdge: 512,
                  preferSourceDetail: true,
                ),
              ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(gateway.imageRequests, hasLength(2));
    expect(gateway.maxActiveImageRequests, 2);

    pending[photos[0].id]!.complete(
      PhotoImageData(
        bytes: fixture,
        width: 1800,
        height: 2700,
        isSourceDetail: false,
      ),
    );
    await tester.pump();
    expect(gateway.imageRequests, hasLength(4));
    expect(gateway.imageRequests.take(4).map((request) => request.id).toSet(), {
      photos[0].id,
      photos[1].id,
    });
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    for (final photo in photos.skip(1)) {
      pending[photo.id]!.complete(
        PhotoImageData(
          bytes: fixture,
          width: 1800,
          height: 2700,
          isSourceDetail: false,
        ),
      );
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 160)),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'in-flight grid promotion survives replacement of next-card lookahead',
    (tester) async {
      final photo = realPhoto('promoted-grid-photo');
      final nextCard = realPhoto(
        'promoted-next-card',
        mediaId: 2,
        generationAdded: 2,
      );
      final obsoleteLookahead = realPhoto(
        'obsolete-lookahead',
        mediaId: 3,
        generationAdded: 3,
      );
      final replacementLookahead = realPhoto(
        'replacement-lookahead',
        mediaId: 4,
        generationAdded: 4,
      );
      final preview = Completer<PhotoImageData?>();
      final detail = Completer<PhotoImageData?>();
      final gateway = FakeSiftGateway()
        ..thumbnailData = fixture
        ..imageCompletersByRequest['${photo.id}|512|false'] = preview
        ..imageCompletersByRequest['${photo.id}|512|true'] = detail;

      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              SizedBox(
                width: 300,
                height: 180,
                child: PhotoArtwork(
                  item: photo,
                  demoMode: false,
                  gateway: gateway,
                  maxEdge: 512,
                  preferSourceDetail: false,
                ),
              ),
              SizedBox(
                width: 300,
                height: 180,
                child: PhotoArtwork(
                  item: photo,
                  demoMode: false,
                  gateway: gateway,
                  maxEdge: 512,
                  preferSourceDetail: true,
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(gateway.imageRequests, hasLength(2));
      expect(
        gateway.imageRequests.where((request) => request.id == photo.id),
        hasLength(2),
      );

      PhotoArtwork.prefetch(
        gateway,
        current: photo,
        detailMaxEdge: 512,
        upcoming: [obsoleteLookahead],
      );
      PhotoArtwork.prefetch(
        gateway,
        current: nextCard,
        detailMaxEdge: 512,
        upcoming: [replacementLookahead],
      );
      preview.complete(
        PhotoImageData(
          bytes: fixture,
          width: 1800,
          height: 2700,
          isSourceDetail: false,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        gateway.imageRequests.where(
          (request) => request.id == obsoleteLookahead.id,
        ),
        isEmpty,
      );
      expect(
        gateway.imageRequests.where(
          (request) => request.id == replacementLookahead.id,
        ),
        isNotEmpty,
      );
      expect(
        gateway.imageRequests.where((request) => request.id == photo.id),
        hasLength(2),
      );

      detail.complete(
        PhotoImageData(
          bytes: fixture,
          width: 1800,
          height: 2700,
          isSourceDetail: true,
        ),
      );
      await _settlePhotoImages(tester, fixture);
      await tester.pumpAndSettle();
      expect(find.text('Photo preview unavailable'), findsNothing);
      expect(find.byType(Image), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bounded FIFO lets every mounted marked-grid tile load', (
    tester,
  ) async {
    final photos = List.generate(
      10,
      (index) => realPhoto(
        'grid-photo-$index',
        mediaId: index + 1,
        generationAdded: index + 1,
      ),
    );
    final pending = {
      for (final photo in photos) photo.id: Completer<PhotoImageData?>(),
    };
    final gateway = FakeSiftGateway()..imageCompletersById.addAll(pending);
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: Wrap(
            children: [
              for (final photo in photos)
                SizedBox(
                  width: 130,
                  height: 170,
                  child: PhotoArtwork(
                    item: photo,
                    demoMode: false,
                    gateway: gateway,
                    maxEdge: 512,
                    preferSourceDetail: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(gateway.imageRequests, hasLength(2));
    for (var index = 0; index < photos.length; index++) {
      pending[photos[index].id]!.complete(
        PhotoImageData(
          bytes: fixture,
          width: 512,
          height: 768,
          isSourceDetail: false,
        ),
      );
      await tester.pump();
      if (index < photos.length - 1) {
        expect(
          gateway.imageRequests,
          hasLength((index + 3).clamp(0, photos.length)),
        );
      }
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 160)),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      gateway.imageRequests.map((request) => request.id).toSet(),
      photos.map((photo) => photo.id).toSet(),
    );
    expect(find.byType(Image), findsNWidgets(photos.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'provider fallback is clearly labeled and failed decode can retry',
    (tester) async {
      final photo = realPhoto('fallback-photo');
      final gateway = FakeSiftGateway()
        ..thumbnailData = fixture
        ..sourceDetailAvailable = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 420,
            child: PhotoArtwork(
              item: photo,
              demoMode: false,
              gateway: gateway,
              maxEdge: 1280,
              preferSourceDetail: true,
            ),
          ),
        ),
      );
      await _settlePhotoImages(tester, fixture);
      await tester.pumpAndSettle();
      expect(find.text('Preview only'), findsOneWidget);

      gateway.thumbnailException = StateError('fixture decode failure');
      PhotoArtwork.invalidate(photo);
      await tester.pumpAndSettle();
      expect(find.text('Photo preview unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(gateway.imageRequests.length, greaterThanOrEqualTo(3));
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _settlePhotoImages(WidgetTester tester, Uint8List bytes) async {
  await tester.runAsync(() async {
    final stream = MemoryImage(bytes).resolve(ImageConfiguration.empty);
    final decoded = Completer<void>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          stream.removeListener(listener);
          image.dispose();
        });
        if (!decoded.isCompleted) decoded.complete();
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
        if (!decoded.isCompleted) decoded.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    await decoded.future.timeout(const Duration(seconds: 5));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

Future<void> _settleRenderedPhotoFrames(WidgetTester tester) async {
  for (var attempt = 0; attempt < 6; attempt++) {
    await tester.pump();
    final providers = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .toSet();
    await tester.runAsync(() async {
      for (final provider in providers) {
        final stream = provider.resolve(ImageConfiguration.empty);
        final decodedOrFailed = Completer<void>();
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (image, _) {
            if (!decodedOrFailed.isCompleted) decodedOrFailed.complete();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              stream.removeListener(listener);
              image.dispose();
            });
          },
        onError: (Object _, StackTrace? _) {
            stream.removeListener(listener);
            if (!decodedOrFailed.isCompleted) decodedOrFailed.complete();
          },
        );
        stream.addListener(listener);
        await decodedOrFailed.future.timeout(const Duration(seconds: 5));
      }
    });
    await tester.pump(const Duration(milliseconds: 80));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
}

Uint8List _padEncodedPng(Uint8List png, int byteLength) {
  if (byteLength < png.length) throw ArgumentError('Target size is too small.');
  return Uint8List(byteLength)..setRange(0, png.length, png);
}
