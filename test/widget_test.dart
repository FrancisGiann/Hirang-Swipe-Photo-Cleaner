import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hirang/data/demo_fixtures.dart';
import 'package:hirang/app/sift_controller.dart';
import 'package:hirang/app/hirang_theme.dart';
import 'package:hirang/domain/review_state.dart';
import 'package:hirang/platform/sift_gateway.dart';
import 'package:hirang/main.dart';
import 'package:hirang/ui/marked_review_screen.dart';
import 'package:hirang/ui/photo_art.dart';
import 'package:hirang/ui/photo_viewer.dart';
import 'package:hirang/ui/sift_home.dart';

import 'support/fake_sift_gateway.dart';

Future<void> _pumpPhotoUi(WidgetTester tester) async {
  // PhotoArtwork intentionally shows an indeterminate loader while a native
  // image request is pending; pump fixed frames instead of settling forever.
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _settleViewerImageFrames(WidgetTester tester) async {
  for (var attempt = 0; attempt < 6; attempt++) {
    await tester.pump();
    final providers = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .toSet();
    await tester.runAsync(() async {
      for (final provider in providers) {
        final stream = provider.resolve(ImageConfiguration.empty);
        final decoded = Completer<void>();
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (image, _) {
            if (!decoded.isCompleted) decoded.complete();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              stream.removeListener(listener);
              image.dispose();
            });
          },
          onError: (Object _, StackTrace? _) {
            stream.removeListener(listener);
            if (!decoded.isCompleted) decoded.complete();
          },
        );
        stream.addListener(listener);
        await decoded.future.timeout(const Duration(seconds: 5));
      }
    });
    await tester.pump(const Duration(milliseconds: 80));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
}

void main() {
  testWidgets(
    'sample deck is plainly labeled and supports Mark, Undo, and filtered progress',
    (tester) async {
      final gateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withDemoMode(true)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: SiftHome(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sample review'), findsOneWidget);
      expect(find.text('FICTIONAL'), findsOneWidget);
      expect(find.byKey(const Key('swipeCardGesture')), findsOneWidget);
      expect(controller.marked, isEmpty);

      await tester.tap(find.byKey(const Key('markButton')));
      await tester.pumpAndSettle();
      expect(controller.marked.map((item) => item.id), ['hirang-demo-1']);
      expect(find.text('1 of 8'), findsOneWidget);

      await tester.tap(find.byKey(const Key('undoButton')));
      await tester.pumpAndSettle();
      expect(controller.marked, isEmpty);
      expect(controller.current?.id, 'hirang-demo-1');
    },
  );

  testWidgets('marked grid refreshes immediately after unmark', (tester) async {
    final photo = PhotoAsset(
      id: 'fiction-mark',
      title: 'Example',
      demoIndex: 0,
    );
    final gateway = FakeSiftGateway()
      ..saved = ReviewState.initial()
          .withDemoMode(true)
          .decide(photo, ReviewDecision.mark);
    final controller = SiftController(gateway);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHirangTheme(Brightness.light),
        darkTheme: buildHirangTheme(Brightness.dark),
        home: MarkedReviewScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Example'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byKey(Key('unmark-${photo.id}')));
    await tester.pumpAndSettle();
    expect(find.text('No sample marks yet'), findsOneWidget);
    expect(find.text('0 selected'), findsNothing);
  });

  testWidgets(
    'marked photo opens a zoomable source-detail viewer without changing selection',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bytes = File('test/fixtures/detail_generated.png')
          .readAsBytesSync();
      final photo = realPhoto('marked-viewer');
      final keptPhoto = realPhoto(
        'marked-viewer-kept',
        mediaId: 20,
        generationAdded: 20,
      );
      final filters = const ReviewFilters(
        album: 'Previously selected album',
        screenshotsOnly: true,
      );
      final savedState = ReviewState.initial()
          .withFilters(filters)
          .decide(photo, ReviewDecision.mark)
          .decide(keptPhoto, ReviewDecision.keep);
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = [photo, keptPhoto]
        ..thumbnailData = Uint8List.fromList(bytes)
        ..thumbnailWidth = 1800
        ..thumbnailHeight = 2700
        ..saved = savedState;
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: MarkedReviewScreen(controller: controller),
        ),
      );
      await _pumpPhotoUi(tester);

      final markedIdsBefore = controller.marked.map((item) => item.id).toList();
      final decisionsBefore = Map<String, ReviewDecision>.of(
        controller.state.decisions,
      );
      expect(markedIdsBefore, [photo.id]);
      expect(find.text('1 selected'), findsOneWidget);
      final openFinder = find.byKey(Key('openMarkedPhoto-${photo.id}'));
      expect(openFinder, findsOneWidget);
      // Invoke two events before the next frame, when an ordinary user can tap
      // again before the pushed fullscreen route has animated on screen.
      final openInkWell = tester.widget<InkWell>(openFinder);
      openInkWell.onTap!();
      openInkWell.onTap!();
      await _pumpPhotoUi(tester);
      await _settleViewerImageFrames(tester);

      expect(find.byKey(const Key('photoViewerInteraction')), findsOneWidget);
      expect(find.byType(PhotoFullscreenViewer), findsOneWidget);
      expect(find.byKey(const Key('closePhotoViewer')), findsOneWidget);
      final viewerSurface = find.byKey(const Key('photoViewerInteraction'));
      expect(
        find.descendant(
          of: viewerSurface,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: viewerSurface, matching: find.text('Preview only')),
        findsNothing,
      );
      expect(
        gateway.imageRequests.any(
          (request) =>
              request.id == photo.id &&
              request.preferSourceDetail &&
              request.maxEdge > 512,
        ),
        isTrue,
        reason: 'The full-screen viewer must request bounded source detail.',
      );
      expect(
        photoImageTargetEdge(const Size(432, 768), 3),
        lessThanOrEqualTo(2048),
      );
      final artworkFinder = find.descendant(
        of: viewerSurface,
        matching: find.byType(PhotoArtwork),
      );
      final artwork = tester.widget<PhotoArtwork>(artworkFinder);
      expect(artwork.fit, BoxFit.contain);
      expect(artwork.maxEdge, greaterThan(512));
      expect(artwork.maxEdge, lessThanOrEqualTo(2048));

      final surface = viewerSurface;
      final center = tester.getCenter(surface);
      final first = await tester.startGesture(
        center - const Offset(30, 0),
        pointer: 1,
      );
      final second = await tester.startGesture(
        center + const Offset(30, 0),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(center - const Offset(60, 0));
      await second.moveTo(center + const Offset(60, 0));
      await tester.pump();
      final viewer = tester.widget<InteractiveViewer>(surface);
      expect(
        viewer.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(1.2),
      );
      await first.up();
      await second.up();
      await _pumpPhotoUi(tester);

      tester.view.physicalSize = const Size(1920, 1080);
      await tester.pump();
      await _pumpPhotoUi(tester);
      await _settleViewerImageFrames(tester);
      final landscapeArtwork = tester.widget<PhotoArtwork>(artworkFinder);
      expect(landscapeArtwork.fit, BoxFit.contain);
      expect(landscapeArtwork.maxEdge, lessThanOrEqualTo(2048));
      expect(
        gateway.imageRequests
            .where((request) => request.id == photo.id)
            .every((request) => request.maxEdge <= 2048),
        isTrue,
      );
      tester.view.physicalSize = const Size(1080, 1920);
      await tester.pump();
      await _pumpPhotoUi(tester);
      await _settleViewerImageFrames(tester);

      await tester.tap(find.byKey(const Key('closePhotoViewer')));
      await _pumpPhotoUi(tester);
      expect(controller.marked.map((item) => item.id), markedIdsBefore);
      expect(controller.state.decisions, decisionsBefore);
      expect(controller.state.filters.toJson(), filters.toJson());
      expect(find.text('1 selected'), findsOneWidget);
      expect(gateway.beginCalls, 0);

      await tester.tap(find.byKey(Key('unmark-${photo.id}')));
      await _pumpPhotoUi(tester);
      expect(controller.marked, isEmpty);
      expect(find.text('Nothing marked'), findsOneWidget);
      expect(gateway.beginCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'viewer back returns to the same scrolled marked grid and filter state',
    (tester) async {
      final filters = const ReviewFilters(
        album: 'Retained filter',
        screenshotsOnly: true,
      );
      var saved = ReviewState.initial().withDemoMode(true).withFilters(filters);
      final photos = DemoFixtures.items.take(6).toList();
      for (final photo in photos) {
        saved = saved.decide(photo, ReviewDecision.mark);
      }
      final gateway = FakeSiftGateway()..saved = saved;
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: MarkedReviewScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      final idsBefore = controller.marked.map((item) => item.id).toList();
      final decisionsBefore = Map<String, ReviewDecision>.of(
        controller.state.decisions,
      );
      final grid = find.byKey(const Key('markedGrid'));
      final scrollable = find
          .descendant(of: grid, matching: find.byType(Scrollable))
          .first;
      final scroll = tester.state<ScrollableState>(scrollable).position;
      scroll.jumpTo(40);
      await tester.pump();
      final scrollBefore = scroll.pixels;
      expect(scrollBefore, greaterThan(0));

      final photo = photos[2];
      final open = tester.widget<InkWell>(
        find.byKey(Key('openMarkedPhoto-${photo.id}')),
      );
      open.onTap!();
      open.onTap!();
      await tester.pumpAndSettle();
      expect(find.byType(PhotoFullscreenViewer), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(controller.marked.map((item) => item.id), idsBefore);
      expect(controller.state.decisions, decisionsBefore);
      expect(controller.state.filters.toJson(), filters.toJson());
      expect(find.text('6 selected'), findsOneWidget);
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        scrollBefore,
      );
      expect(gateway.beginCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'marked photo viewer labels a smaller fallback and retries a stale photo safely',
    (tester) async {
      final bytes = Uint8List.fromList(
        File('test/fixtures/detail_generated.png').readAsBytesSync(),
      );
      final photo = realPhoto('marked-stale-viewer');
      var mediaAvailable = false;
      var detailAvailable = false;
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'limited', sdkInt: 36)
        ..photos = [photo]
        ..photoImageLoader = (item, maxEdge, sourceDetail) async {
          if (!mediaAvailable) return null;
          return PhotoImageData(
            bytes: bytes,
            width: 1800,
            height: 2700,
            isSourceDetail: sourceDetail && detailAvailable,
          );
        }
        ..saved = ReviewState.initial().decide(photo, ReviewDecision.mark);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: MarkedReviewScreen(controller: controller),
        ),
      );
      await _pumpPhotoUi(tester);
      await tester.tap(find.byKey(Key('openMarkedPhoto-${photo.id}')));
      await _pumpPhotoUi(tester);
      expect(find.text('Photo preview unavailable'), findsOneWidget);

      mediaAvailable = true;
      final viewer = find.byKey(const Key('photoViewerInteraction'));
      await tester.tap(
        find.descendant(
          of: viewer,
          matching: find.byIcon(Icons.refresh_rounded),
        ),
      );
      await _pumpPhotoUi(tester);
      await _settleViewerImageFrames(tester);
      expect(find.text('Preview only'), findsOneWidget);
      expect(find.byTooltip('Retry higher-detail photo'), findsOneWidget);

      detailAvailable = true;
      await tester.tap(
        find.descendant(
          of: viewer,
          matching: find.byIcon(Icons.refresh_rounded),
        ),
      );
      await _pumpPhotoUi(tester);
      await _settleViewerImageFrames(tester);
      expect(find.text('Preview only'), findsNothing);
      expect(controller.marked.map((item) => item.id), [photo.id]);
      expect(gateway.beginCalls, 0);
      await tester.binding.handlePopRoute();
      await _pumpPhotoUi(tester);
      expect(controller.marked.map((item) => item.id), [photo.id]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing during a pending detail load safely ignores the late image result',
    (tester) async {
      final bytes = Uint8List.fromList(
        File('test/fixtures/detail_generated.png').readAsBytesSync(),
      );
      final sourceDetail = Completer<PhotoImageData?>();
      final photo = realPhoto('marked-pending-viewer');
      final preview = PhotoImageData(
        bytes: bytes,
        width: 1800,
        height: 2700,
        isSourceDetail: false,
      );
      final fullImage = PhotoImageData(
        bytes: bytes,
        width: 1800,
        height: 2700,
        isSourceDetail: true,
      );
      final gateway = FakeSiftGateway();
      gateway
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = [photo]
        ..photoImageLoader = (item, maxEdge, preferSourceDetail) async {
          if (preferSourceDetail) return sourceDetail.future;
          return preview;
        }
        ..saved = ReviewState.initial().decide(photo, ReviewDecision.mark);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: MarkedReviewScreen(controller: controller),
        ),
      );
      await _pumpPhotoUi(tester);
      await tester.tap(find.byKey(Key('openMarkedPhoto-${photo.id}')));
      await _pumpPhotoUi(tester);
      expect(find.byKey(const Key('photoViewerInteraction')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('photoViewerInteraction')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsWidgets,
      );
      expect(controller.marked.map((item) => item.id), [photo.id]);

      await tester.binding.handlePopRoute();
      await _pumpPhotoUi(tester);
      sourceDetail.complete(fullImage);
      await _pumpPhotoUi(tester);

      expect(find.byKey(const Key('photoViewerInteraction')), findsNothing);
      expect(controller.marked.map((item) => item.id), [photo.id]);
      expect(controller.state.operation, isNull);
      expect(gateway.beginCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'trash preflight freezes its count and rejects an unmark already in flight',
    (tester) async {
      final first = realPhoto('preflight-first');
      final second = realPhoto(
        'preflight-second',
        mediaId: 2,
        generationAdded: 2,
      );
      final revalidation = Completer<List<Revalidation>>();
      final queuedSave = Completer<void>();
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = [first, second]
        ..saved = ReviewState.initial()
            .decide(first, ReviewDecision.mark)
            .decide(second, ReviewDecision.mark)
        ..revalidationCompleter = revalidation
        ..saveCompleter = queuedSave;
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: MarkedReviewScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      // Start an asynchronous unmark immediately before tapping Trash. Its
      // save can finish while the fixed preflight snapshot is being checked.
      final queuedUnmark = controller.unmark(first.id);
      await tester.tap(find.byKey(const Key('trashMarkedButton')));
      await tester.pump();
      expect(gateway.revalidatedIds, [first.id, second.id]);
      expect(controller.marked.map((item) => item.id), [first.id, second.id]);
      expect(
        tester
            .widget<IconButton>(find.byKey(Key('unmark-${first.id}')))
            .onPressed,
        isNull,
      );
      queuedSave.complete();
      await queuedUnmark;
      await tester.pump();

      expect(gateway.revalidatedIds, [first.id, second.id]);
      expect(controller.marked.map((item) => item.id), [second.id]);
      expect(
        tester
            .widget<IconButton>(find.byKey(Key('unmark-${second.id}')))
            .onPressed,
        isNull,
      );

      revalidation.complete([
        Revalidation(id: first.id, status: 'present'),
        Revalidation(id: second.id, status: 'present'),
      ]);
      await tester.pump();
      expect(
        find.textContaining('2 marked photos are selected'),
        findsOneWidget,
      );

      await tester.tap(find.text('Review system confirmation'));
      await tester.pumpAndSettle();
      expect(gateway.beginCalls, 0);
      expect(controller.state.operation, isNull);
      expect(
        find.textContaining(
          'The marked selection changed while it was being checked',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'system trash request waits for explicit confirmation and backs out safely',
    (tester) async {
      final photo = realPhoto('explicit-system-confirmation');
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = [photo]
        ..saved = ReviewState.initial()
            .decide(photo, ReviewDecision.mark)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: MarkedReviewScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('trashMarkedButton')));
      for (
        var attempt = 0;
        attempt < 12 &&
            find.text('Review before system trash').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Review before system trash'), findsOneWidget);
      expect(
        find.textContaining(
          'Photos are not moved to trash until you approve it.',
        ),
        findsOneWidget,
      );
      expect(gateway.beginCalls, 0);
      expect(controller.state.operation, isNull);

      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(gateway.beginCalls, 0);
      expect(controller.state.operation, isNull);

      await tester.tap(find.byKey(const Key('trashMarkedButton')));
      for (
        var attempt = 0;
        attempt < 12 &&
            find.text('Review before system trash').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byKey(const Key('reviewSystemConfirmationButton')));
      for (
        var attempt = 0;
        attempt < 12 &&
            controller.state.operation?.status != 'awaitingSystemApproval';
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(gateway.beginCalls, 1);
      expect(controller.state.operation?.status, 'awaitingSystemApproval');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow large-text home keeps primary controls available', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FakeSiftGateway()
      ..saved = ReviewState.initial()
          .withDemoMode(true)
          .copyWith(onboardingComplete: true);
    final controller = SiftController(gateway);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHirangTheme(Brightness.light),
        darkTheme: buildHirangTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 720),
            textScaler: TextScaler.linear(2),
          ),
          child: SiftHome(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('filtersButton')), findsOneWidget);
    expect(find.byKey(const Key('markedReviewButton')), findsOneWidget);
    expect(find.byKey(const Key('photoOptionsButton')), findsOneWidget);
    expect(find.byKey(const Key('markButton')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('left and right drags commit one matching decision', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FakeSiftGateway()
      ..saved = ReviewState.initial()
          .withDemoMode(true)
          .copyWith(onboardingComplete: true);
    final controller = SiftController(gateway);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHirangTheme(Brightness.light),
        darkTheme: buildHirangTheme(Brightness.dark),
        home: SiftHome(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    await _swipe(tester, const Offset(-220, 0));
    expect(controller.state.decisions, {'hirang-demo-1': ReviewDecision.mark});
    expect(controller.current?.id, 'hirang-demo-2');
    expect(tester.takeException(), isNull);

    await controller.undo();
    await tester.pumpAndSettle();
    await _swipe(tester, const Offset(220, 0));
    expect(controller.state.decisions, {'hirang-demo-1': ReviewDecision.keep});
    expect(controller.state.undoHistory, ['hirang-demo-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'swipe intent follows held offset, reverses, and cancel never decides',
    (tester) async {
      final gateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withDemoMode(true)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: SiftHome(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(const Key('swipeCardGesture'));
      final initialCenter = tester.getCenter(card);
      final gesture = await tester.startGesture(initialCenter);
      await gesture.moveBy(const Offset(-44, 0));
      await tester.pump();

      expect(controller.state.decisions, isEmpty);
      expect(find.text('MARK FOR REMOVAL'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('swipeIntentStamp')),
          matching: find.byIcon(Icons.bookmark_add_rounded),
        ),
        findsOneWidget,
      );
      final markStamp = tester.widget<Material>(
        find.byKey(const Key('swipeIntentStamp')),
      );
      expect(
        markStamp.color,
        Theme.of(tester.element(card))
            .extension<HirangSemanticColors>()!
            .markBackground,
      );
      expect(_feedbackOpacity(tester, 'MARK FOR REMOVAL'), closeTo(.5, .01));

      await gesture.moveBy(const Offset(66, 0));
      await tester.pump();
      expect(controller.state.decisions, isEmpty);
      expect(find.text('MARK FOR REMOVAL'), findsNothing);
      expect(find.text('KEEP'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('swipeIntentStamp')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      final keepStamp = tester.widget<Material>(
        find.byKey(const Key('swipeIntentStamp')),
      );
      expect(
        keepStamp.color,
        Theme.of(tester.element(card))
            .extension<HirangSemanticColors>()!
            .keepBackground,
      );
      expect(_feedbackOpacity(tester, 'KEEP'), closeTo(.25, .02));

      await gesture.moveBy(const Offset(-44, 0));
      await tester.pump();
      expect(find.text('MARK FOR REMOVAL'), findsOneWidget);
      expect(_feedbackOpacity(tester, 'MARK FOR REMOVAL'), closeTo(.25, .02));
      expect(controller.state.decisions, isEmpty);

      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(find.text('MARK FOR REMOVAL'), findsOneWidget);
      expect(_feedbackOpacity(tester, 'MARK FOR REMOVAL'), 1);
      expect(controller.state.decisions, isEmpty);

      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(controller.state.decisions, isEmpty);
      expect(controller.current?.id, 'hirang-demo-1');
      expect(find.byKey(const Key('swipeIntentStamp')), findsNothing);
      expect(tester.getCenter(card).dx, closeTo(initialCenter.dx, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fast release below the shared threshold returns; threshold release commits once',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withDemoMode(true)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 720),
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: SiftHome(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(const Key('swipeCardGesture'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      final detector = tester.widget<GestureDetector>(card);
      final center = tester.getCenter(card);
      detector.onPanStart!(DragStartDetails(globalPosition: center));
      detector.onPanUpdate!(
        DragUpdateDetails(
          globalPosition: center + const Offset(80, 0),
          delta: const Offset(80, 0),
          primaryDelta: 80,
        ),
      );
      await tester.pump();
      expect(controller.state.decisions, isEmpty);
      expect(find.text('KEEP'), findsOneWidget);
      expect(
        _feedbackOpacity(tester, 'KEEP'),
        closeTo(80 / swipeDecisionThreshold, .01),
      );
      detector.onPanEnd!(
        DragEndDetails(
          velocity: Velocity(pixelsPerSecond: const Offset(4800, 0)),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.state.decisions, isEmpty);
      expect(controller.current?.id, 'hirang-demo-1');
      expect(find.byKey(const Key('swipeIntentStamp')), findsNothing);

      detector.onPanStart!(DragStartDetails(globalPosition: center));
      detector.onPanUpdate!(
        DragUpdateDetails(
          globalPosition: center + Offset(swipeDecisionThreshold, 0),
          delta: Offset(swipeDecisionThreshold, 0),
          primaryDelta: swipeDecisionThreshold,
        ),
      );
      await tester.pump();
      expect(controller.state.decisions, isEmpty);
      expect(_feedbackOpacity(tester, 'KEEP'), 1);
      detector.onPanEnd!(DragEndDetails(velocity: Velocity.zero));
      await tester.pumpAndSettle();
      expect(controller.state.decisions, {
        'hirang-demo-1': ReviewDecision.keep,
      });
      expect(controller.state.undoHistory, ['hirang-demo-1']);
      expect(controller.current?.id, 'hirang-demo-2');
      expect(tester.takeException(), isNull);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'caught-up screen keeps Undo available after the final decision',
    (tester) async {
      final startingState = DemoFixtures.items
          .take(DemoFixtures.items.length - 1)
          .fold<ReviewState>(
            ReviewState.initial().withDemoMode(true),
            (state, item) => state.decide(item, ReviewDecision.keep),
          );
      final gateway = FakeSiftGateway()
        ..saved = startingState.copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: SiftHome(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.current?.id, DemoFixtures.items.last.id);
      await tester.tap(find.byKey(const Key('keepButton')));
      await tester.pumpAndSettle();
      expect(controller.current, isNull);
      expect(find.byKey(const Key('caughtUpUndoButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('caughtUpUndoButton')));
      await tester.pumpAndSettle();
      expect(controller.current?.id, DemoFixtures.items.last.id);
      expect(
        controller.state.decisions,
        hasLength(DemoFixtures.items.length - 1),
      );
    },
  );

  testWidgets(
    'unavailable saved filter remains valid after limited access changes',
    (tester) async {
      final gateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withFilters(
              const ReviewFilters(album: 'Previously selected album'),
            )
            .copyWith(onboardingComplete: true)
        ..access = const PhotoAccess(status: 'limited', sdkInt: 36)
        ..photos = [realPhoto('accessible-photo')];
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: SiftHome(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(controller.state.filters.album, 'Previously selected album');
      expect(find.byKey(const Key('photoOptionsButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('photoOptionsButton')));
      await tester.pumpAndSettle();
      expect(find.text('Choose more photos'), findsOneWidget);
      await tester.tap(find.text('Android app settings').first);
      await tester.pumpAndSettle();
      expect(gateway.appSettingsOpened, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'regrabbing a dismissing card cancels the stale decision and settle',
    (tester) async {
      tester.view.physicalSize = const Size(480, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withDemoMode(true)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHirangTheme(Brightness.light),
          darkTheme: buildHirangTheme(Brightness.dark),
          home: SiftHome(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(const Key('swipeCardGesture'));
      final initial = tester.getCenter(card);
      final first = await tester.startGesture(initial);
      await first.moveBy(const Offset(-220, 0));
      await first.up();
      await tester.pump(const Duration(milliseconds: 110));

      final movingCenter = tester.getCenter(card);
      final correction = initial.dx - movingCenter.dx;
      final second = await tester.startGesture(movingCenter);
      await second.moveBy(Offset(correction / 2, 0));
      await tester.pump(const Duration(milliseconds: 250));
      await second.moveBy(Offset(correction / 2, 0));
      await tester.pump(const Duration(milliseconds: 250));
      await second.up();
      await tester.pumpAndSettle();

      expect(controller.state.decisions, isEmpty);
      expect(controller.current?.id, 'hirang-demo-1');
      expect(tester.getCenter(card).dx, closeTo(initial.dx, 1));
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _swipe(WidgetTester tester, Offset delta) async {
  final card = find.byKey(const Key('swipeCardGesture'));
  final gesture = await tester.startGesture(tester.getCenter(card));
  await gesture.moveBy(delta);
  await gesture.up();
  await tester.pumpAndSettle();
}

double _feedbackOpacity(WidgetTester tester, String label) {
  final opacityFinder = find
      .ancestor(of: find.text(label), matching: find.byType(Opacity))
      .first;
  return tester.widget<Opacity>(opacityFinder).opacity;
}
