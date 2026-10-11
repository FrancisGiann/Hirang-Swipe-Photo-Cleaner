import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hirang/app/sift_controller.dart';
import 'package:hirang/data/demo_fixtures.dart';
import 'package:hirang/domain/hirang_theme_id.dart';
import 'package:hirang/domain/review_state.dart';
import 'package:hirang/main.dart';
import 'package:hirang/platform/sift_gateway.dart';
import 'package:hirang/ui/marked_review_screen.dart';
import 'package:hirang/ui/onboarding_screen.dart';
import 'package:hirang/ui/photo_art.dart';
import 'package:hirang/ui/sift_home.dart';

import 'support/fake_sift_gateway.dart';

const _fixture = PhotoAsset(
  id: 'visual-fixture-screenshot-01',
  title: 'Screenshot_20261010-133225.jpg',
  uri: 'content://media/external_primary/images/media/83001',
  volumeName: 'external_primary',
  mediaId: 83001,
  generationAdded: 22,
  generationModified: 31,
  volumeVersion: 'render-fixture-v1',
  album: 'Weekend market and street scenes',
  relativePath: 'Pictures/Screenshots/',
  dateTakenMillis: 1791635520000,
  sizeBytes: 987 * 1024,
  screenshotHeuristic: true,
);

const _fixtureSecond = PhotoAsset(
  id: 'visual-fixture-screenshot-02',
  title: 'Screenshot_20261010-133240.jpg',
  uri: 'content://media/external_primary/images/media/83002',
  volumeName: 'external_primary',
  mediaId: 83002,
  generationAdded: 23,
  generationModified: 32,
  volumeVersion: 'render-fixture-v1',
  album: 'Weekend market and street scenes',
  relativePath: 'Pictures/Screenshots/',
  dateTakenMillis: 1791635530000,
  sizeBytes: 512 * 1024,
  screenshotHeuristic: true,
);

class _VisualReviewBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  _VisualReviewBinding();

  setUpAll(_loadRenderFonts);

  testWidgets(
    'captures onboarding, full-access deck, filters, details, marked review and confirmation',
    (tester) async {
      final dpr = await _configure(tester, const Size(393, 886), scale: 1);
      final introController = SiftController(FakeSiftGateway());
      await introController.initialize();
      await _pump(tester, OnboardingScreen(controller: introController));
      debugPrint('VISUAL_CAPTURE: welcome');
      await _capture(tester, '01-welcome-393-light.png', dpr);
      await tester.tap(find.byKey(const Key('onboardingContinueButton')));
      await tester.pumpAndSettle();
      expect(find.text('Try one sample card'), findsOneWidget);
      debugPrint('VISUAL_CAPTURE: practice');
      await _capture(tester, '02-practice-393-light.png', dpr);
      await tester.tap(find.byKey(const Key('practiceMarkButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Marked for review'), findsOneWidget);
      await _capture(tester, '03-practice-marked-393-light.png', dpr);
      await tester.tap(find.byKey(const Key('onboardingContinueButton')));
      await tester.pumpAndSettle();
      expect(find.text('Mark is not trash'), findsOneWidget);
      await _capture(tester, '04-trash-explanation-393-light.png', dpr);
      await tester.tap(find.byKey(const Key('onboardingContinueButton')));
      await tester.pumpAndSettle();
      expect(find.text('Choose your next step'), findsOneWidget);
      await _capture(tester, '05-choose-photos-393-light.png', dpr);
      expect(tester.takeException(), isNull);

      final thumbnail = await _generatedFixturePng();
      final full = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = const [_fixture]
        ..thumbnailData = thumbnail
        ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
      final controller = SiftController(full);
      await controller.initialize();
      PhotoArtwork.invalidateAll();
      await _pump(tester, SiftHome(controller: controller));
      await _settleImages(tester);
      await tester.pumpAndSettle();
      expect(find.text('Screenshot_20261010-133225.jpg'), findsOneWidget);
      await _capture(tester, '06-full-library-deck-393-light.png', dpr);
      expect(tester.takeException(), isNull);

      final sampleGateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withDemoMode(true)
            .copyWith(onboardingComplete: true);
      final sampleController = SiftController(sampleGateway);
      await sampleController.initialize();
      PhotoArtwork.invalidateAll();
      await _pump(tester, SiftHome(controller: sampleController));
      await tester.pumpAndSettle();
      expect(find.text('Sample review'), findsOneWidget);
      expect(find.text('FICTIONAL'), findsOneWidget);
      expect(find.byKey(const Key('swipeCardGesture')), findsOneWidget);
      await _settleImages(tester);
      await _capture(tester, '27-sample-deck-393-light.png', dpr);
      expect(tester.takeException(), isNull);

      await _pump(tester, SiftHome(controller: controller));
      await tester.pumpAndSettle();
      await _settleImages(tester);
      await tester.tap(find.byKey(const Key('filtersButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filterSheet')), findsOneWidget);
      await _capture(tester, '07-filter-sheet-393-light.png', dpr);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('photoDetailsButton')));
      await tester.pumpAndSettle();
      expect(find.text('Photo details'), findsOneWidget);
      await _capture(tester, '08-photo-details-393-light.png', dpr);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('photoOptionsButton')));
      await tester.pumpAndSettle();
      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.text('How Hirang works').hitTestable(), findsOneWidget);
      await _capture(tester, '20-photo-options-393-light.png', dpr);
      await tester.tap(find.text('How Hirang works'));
      await tester.pumpAndSettle();
      await _capture(tester, '21-how-it-works-393-light.png', dpr);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('markButton')));
      await tester.pumpAndSettle();
      expect(controller.marked.map((item) => item.id), [_fixture.id]);
      await tester.tap(find.byKey(const Key('markedReviewButton')));
      await tester.pumpAndSettle();
      expect(find.byType(MarkedReviewScreen), findsOneWidget);
      await _capture(tester, '09-marked-review-393-light.png', dpr);

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
      expect(find.textContaining('1 marked photo is selected'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(AlertDialog).hitTestable(), findsOneWidget);
      expect(
        find.textContaining('Android may later expire trashed items'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Photos are not moved to trash until you approve it.',
        ),
        findsOneWidget,
      );
      await _capture(tester, '10-trash-confirmation-393-light.png', dpr);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'captures responsive, dark and access/empty/error states without overflows',
    (tester) async {
      final thumbnail = await _generatedFixturePng();
      var dpr = await _configure(tester, const Size(360, 812), scale: 1.5);
      final narrowGateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = const [_fixture]
        ..thumbnailData = thumbnail
        ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
      final narrowController = SiftController(narrowGateway);
      await narrowController.initialize();
      PhotoArtwork.invalidateAll();
      await _pump(tester, SiftHome(controller: narrowController));
      await _settleImages(tester);
      await tester.pumpAndSettle();
      await _capture(tester, '11-full-library-narrow-360-large-text.png', dpr);
      expect(tester.takeException(), isNull);

      dpr = await _configure(
        tester,
        const Size(393, 886),
        scale: 1,
        brightness: Brightness.dark,
      );
      final darkGateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = const [_fixture]
        ..thumbnailData = thumbnail
        ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
      final darkController = SiftController(darkGateway);
      await darkController.initialize();
      PhotoArtwork.invalidateAll();
      await _pump(tester, SiftHome(controller: darkController));
      await _settleImages(tester);
      await tester.pumpAndSettle();
      await _capture(tester, '12-full-library-deck-393-dark.png', dpr);
      expect(tester.takeException(), isNull);

      dpr = await _configure(tester, const Size(393, 886), scale: 1);
      final limitedGateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'limited', sdkInt: 36)
        ..photos = const [_fixture]
        ..thumbnailData = thumbnail
        ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
      final limitedController = SiftController(limitedGateway);
      await limitedController.initialize();
      PhotoArtwork.invalidateAll();
      await _pump(tester, SiftHome(controller: limitedController));
      await _settleImages(tester);
      await tester.pumpAndSettle();
      await _capture(tester, '13-limited-access-393-light.png', dpr);
      expect(tester.takeException(), isNull);

      final deniedGateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'denied', sdkInt: 36)
        ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
      final deniedController = SiftController(deniedGateway);
      await deniedController.initialize();
      await _pump(tester, SiftHome(controller: deniedController));
      await tester.pumpAndSettle();
      await _capture(tester, '14-photo-access-off-393-light.png', dpr);
      expect(tester.takeException(), isNull);

      final emptyGateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = const []
        ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
      final emptyController = SiftController(emptyGateway);
      await emptyController.initialize();
      await _pump(tester, SiftHome(controller: emptyController));
      await tester.pumpAndSettle();
      await _capture(tester, '15-empty-library-393-light.png', dpr);
      expect(tester.takeException(), isNull);

      final errorGateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..queryException = StateError('fixture query failure')
        ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
      final errorController = SiftController(errorGateway);
      await errorController.initialize();
      await _pump(tester, SiftHome(controller: errorController));
      await tester.pumpAndSettle();
      await _capture(tester, '16-library-error-393-light.png', dpr);
      expect(tester.takeException(), isNull);

      final loadingGateway = FakeSiftGateway()
        ..loadCompleter = Completer<ReviewState>()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = const [_fixture]
        ..thumbnailData = thumbnail;
      final loadingController = SiftController(loadingGateway);
      await _pump(tester, SiftHome(controller: loadingController));
      await tester.pump();
      await _capture(tester, '17-startup-loading-393-light.png', dpr);
      loadingGateway.loadCompleter!.complete(
        ReviewState.initial().copyWith(onboardingComplete: true),
      );
      for (
        var attempt = 0;
        attempt < 20 && !loadingController.startupReady;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(loadingController.startupReady, isTrue);
      expect(tester.takeException(), isNull);

      final savedStateError = FakeSiftGateway()
        ..loadException = StateError('fixture unreadable storage')
        ..access = const PhotoAccess(status: 'full', sdkInt: 36);
      final blockedController = SiftController(savedStateError);
      await blockedController.initialize();
      await _pump(tester, SiftHome(controller: blockedController));
      await tester.pumpAndSettle();
      await _capture(tester, '18-saved-review-retry-393-light.png', dpr);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'captures screen-sized source detail and enlarged photo at DPR 3',
    (tester) async {
      final dpr = await _configure(
        tester,
        const Size(360, 800),
        scale: 1,
        dpr: 3,
      );
      final gateway = FakeSiftGateway()
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = const [_fixture]
        ..photoImageLoader = _boundedDetailFixture
        ..saved = ReviewState.initial().copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      PhotoArtwork.invalidateAll();
      await _pump(tester, SiftHome(controller: controller));
      await _settleImages(tester);
      await tester.pumpAndSettle();
      expect(gateway.imageRequests, isNotEmpty);
      final initialRequests = gateway.imageRequests.take(2).toList();
      expect(initialRequests, hasLength(2));
      expect(
        initialRequests.every((request) => request.id == _fixture.id),
        isTrue,
      );
      expect(
        initialRequests
            .where((request) => !request.preferSourceDetail)
            .single
            .maxEdge,
        512,
      );
      final detailRequest = gateway.imageRequests.firstWhere(
        (request) => request.preferSourceDetail,
      );
      expect(detailRequest.maxEdge, greaterThan(512));
      final firstImage = await gateway.photoImageLoader!(
        _fixture,
        detailRequest.maxEdge,
        true,
      );
      expect(firstImage, isNotNull);
      expect(firstImage!.width * firstImage.height, lessThanOrEqualTo(3000000));
      expect(math.max(firstImage.width, firstImage.height), greaterThan(768));
      expect(firstImage.width, lessThanOrEqualTo(detailRequest.maxEdge));
      expect(firstImage.height, lessThanOrEqualTo(detailRequest.maxEdge));
      await _capture(tester, '33-photo-detail-deck-360-dpr3.png', dpr);

      await tester.tap(find.byKey(const Key('photoDetailsButton')));
      await tester.pumpAndSettle();
      expect(find.text('Photo details'), findsOneWidget);
      await tester.tap(find.byKey(const Key('viewPhotoLargerButton')));
      await _settleImages(tester);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close photo preview'), findsOneWidget);
      expect(gateway.imageRequests.length, greaterThanOrEqualTo(2));
      expect(gateway.imageRequests.last.preferSourceDetail, isTrue);
      expect(gateway.imageRequests.last.maxEdge, lessThanOrEqualTo(2048));
      final viewerRequest = gateway.imageRequests.last;
      final viewerImage = await gateway.photoImageLoader!(
        _fixture,
        viewerRequest.maxEdge,
        viewerRequest.preferSourceDetail,
      );
      expect(viewerImage, isNotNull);
      expect(
        viewerImage!.width * viewerImage.height,
        lessThanOrEqualTo(3000000),
      );
      expect(viewerImage.width, lessThanOrEqualTo(viewerRequest.maxEdge));
      expect(viewerImage.height, lessThanOrEqualTo(viewerRequest.maxEdge));
      await _capture(tester, '34-photo-detail-viewer-360-dpr3.png', dpr);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('captures a verified-result panel', (tester) async {
    final dpr = await _configure(tester, const Size(393, 886), scale: 1);
    final gateway = FakeSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..photos = const []
      ..thumbnailData = await _generatedFixturePng()
      ..saved = ReviewState.initial()
          .decide(_fixture, ReviewDecision.mark)
          .copyWith(onboardingComplete: true)
      ..operation = TrashOperation(
        id: 'render-verified-trash',
        createdAtMillis: 1,
        items: const [_fixture],
        outcomes: {_fixture.id: OperationItemOutcome.trashed},
        status: 'complete',
      );
    final controller = SiftController(gateway);
    await controller.initialize();
    PhotoArtwork.invalidateAll();
    await _pump(tester, SiftHome(controller: controller));
    await tester.pumpAndSettle();
    await _capture(tester, '19-verified-result-393-light.png', dpr);
    expect(
      find.textContaining('1 photo was verified in system trash'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('captures onboarding at large text and in dark mode', (
    tester,
  ) async {
    var dpr = await _configure(tester, const Size(393, 886), scale: 1.5);
    final largeController = SiftController(FakeSiftGateway());
    await largeController.initialize();
    await _pump(tester, OnboardingScreen(controller: largeController));
    await tester.pumpAndSettle();
    await _capture(tester, '22-welcome-large-text-393-light.png', dpr);
    await tester.tap(find.byKey(const Key('onboardingContinueButton')));
    await tester.pumpAndSettle();
    final continueButton = find.byKey(const Key('onboardingContinueButton'));
    expect(continueButton.hitTestable(), findsOneWidget);
    final continueRect = tester.getRect(continueButton);
    expect(continueRect.top, greaterThanOrEqualTo(0));
    expect(continueRect.bottom, lessThanOrEqualTo(886));
    await _capture(tester, '23-practice-large-text-393-light.png', dpr);
    expect(tester.takeException(), isNull);

    dpr = await _configure(
      tester,
      const Size(393, 886),
      scale: 1,
      brightness: Brightness.dark,
    );
    final darkController = SiftController(FakeSiftGateway());
    await darkController.initialize();
    await _pump(tester, OnboardingScreen(controller: darkController));
    await tester.pumpAndSettle();
    expect(find.text('A calmer way to review your photos.'), findsOneWidget);
    await _capture(tester, '24-welcome-393-dark.png', dpr);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captures partial and cancelled result states', (tester) async {
    final dpr = await _configure(tester, const Size(393, 886), scale: 1);
    final second = PhotoAsset(
      id: 'visual-fixture-screenshot-02',
      title: 'Screenshot_20261010-133240.jpg',
      uri: 'content://media/external_primary/images/media/83002',
      volumeName: 'external_primary',
      mediaId: 83002,
      generationAdded: 23,
      generationModified: 32,
      volumeVersion: 'render-fixture-v1',
      album: 'Weekend market and street scenes',
      relativePath: 'Pictures/Screenshots/',
      dateTakenMillis: 1791635530000,
      sizeBytes: 512 * 1024,
      screenshotHeuristic: true,
    );

    final partial = FakeSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..photos = [second]
      ..thumbnailData = await _generatedFixturePng()
      ..saved = ReviewState.initial()
          .decide(_fixture, ReviewDecision.mark)
          .decide(second, ReviewDecision.mark)
          .copyWith(onboardingComplete: true)
      ..operation = TrashOperation(
        id: 'render-partial-result',
        createdAtMillis: 1,
        items: [_fixture, second],
        outcomes: {
          _fixture.id: OperationItemOutcome.trashed,
          second.id: OperationItemOutcome.stillPresent,
        },
        status: 'complete',
      );
    final partialController = SiftController(partial);
    await partialController.initialize();
    await _pump(tester, SiftHome(controller: partialController));
    await tester.pumpAndSettle();
    await _capture(tester, '25-partial-result-393-light.png', dpr);
    expect(find.text('1/2'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final cancelled = FakeSiftGateway()
      ..access = const PhotoAccess(status: 'full', sdkInt: 36)
      ..photos = [_fixture, second]
      ..thumbnailData = await _generatedFixturePng()
      ..saved = ReviewState.initial()
          .decide(_fixture, ReviewDecision.mark)
          .decide(second, ReviewDecision.mark)
          .copyWith(onboardingComplete: true)
      ..operation = TrashOperation(
        id: 'render-cancelled-result',
        createdAtMillis: 1,
        items: [_fixture, second],
        outcomes: {
          _fixture.id: OperationItemOutcome.cancelled,
          second.id: OperationItemOutcome.unknown,
        },
        status: 'cancelled',
      );
    final cancelledController = SiftController(cancelled);
    await cancelledController.initialize();
    await _pump(tester, SiftHome(controller: cancelledController));
    await tester.pumpAndSettle();
    await _capture(tester, '26-cancelled-result-393-light.png', dpr);
    expect(find.text('Trash request cancelled'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captures live mark and keep intent plus snapback', (
    tester,
  ) async {
    final dpr = await _configure(tester, const Size(393, 886), scale: 1);
    final gateway = FakeSiftGateway()
      ..saved = ReviewState.initial()
          .withDemoMode(true)
          .copyWith(onboardingComplete: true);
    final controller = SiftController(gateway);
    await controller.initialize();
    PhotoArtwork.invalidateAll();
    await _pump(tester, SiftHome(controller: controller));
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('swipeCardGesture'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(find.text('MARK FOR REMOVAL'), findsOneWidget);
    expect(controller.state.decisions, isEmpty);
    await _capture(tester, '28-swipe-mark-intent-393-light.png', dpr);

    await gesture.moveBy(const Offset(132, 0));
    await tester.pump();
    expect(find.text('KEEP'), findsOneWidget);
    expect(find.text('MARK FOR REMOVAL'), findsNothing);
    expect(controller.state.decisions, isEmpty);
    await _capture(tester, '29-swipe-keep-intent-393-light.png', dpr);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.state.decisions, isEmpty);
    expect(controller.current?.id, 'hirang-demo-1');
    expect(find.byKey(const Key('swipeIntentStamp')), findsNothing);
    await _capture(tester, '30-swipe-snapback-393-light.png', dpr);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captures dark large-text mark intent and snapback', (
    tester,
  ) async {
    final dpr = await _configure(
      tester,
      const Size(320, 720),
      scale: 2,
      brightness: Brightness.dark,
    );
    final gateway = FakeSiftGateway()
      ..saved = ReviewState.initial()
          .withDemoMode(true)
          .copyWith(onboardingComplete: true);
    final controller = SiftController(gateway);
    await controller.initialize();
    PhotoArtwork.invalidateAll();
    await _pump(tester, SiftHome(controller: controller));
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('swipeCardGesture'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final detector = tester.widget<GestureDetector>(card);
    final center = tester.getCenter(card);
    detector.onPanStart!(DragStartDetails(globalPosition: center));
    detector.onPanUpdate!(
      DragUpdateDetails(
        globalPosition: center + const Offset(-60, 0),
        delta: const Offset(-60, 0),
        primaryDelta: -60,
      ),
    );
    await tester.pump();
    expect(find.text('MARK FOR REMOVAL'), findsOneWidget);
    expect(controller.state.decisions, isEmpty);
    await _capture(tester, '31-swipe-mark-dark-large-text-320.png', dpr);
    expect(tester.takeException(), isNull);

    detector.onPanEnd!(DragEndDetails(velocity: Velocity.zero));
    await tester.pumpAndSettle();
    expect(controller.state.decisions, isEmpty);
    expect(controller.current?.id, 'hirang-demo-1');
    expect(find.byKey(const Key('swipeIntentStamp')), findsNothing);
    await _capture(tester, '32-swipe-snapback-dark-large-text-320.png', dpr);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'captures each palette across welcome, deck, review, help, Settings and error states',
    (tester) async {
      final dpr = await _configure(
        tester,
        const Size(393, 886),
        scale: 1,
        dpr: 1,
      );
      final marketFixture = await _generatedFixturePng();
      var captureIndex = 35;

      for (final id in HirangThemeId.values) {
        final introGateway = FakeSiftGateway()
          ..saved = ReviewState.initial().copyWith(themeId: id);
        final introController = SiftController(introGateway);
        await introController.initialize();
        await _pumpSiftApp(tester, introController, '${id.storageId}-welcome');
        expect(
          find.textContaining('A calmer way to review your photos'),
          findsOneWidget,
        );
        await _capture(
          tester,
          '${(captureIndex++).toString().padLeft(2, '0')}-${id.storageId}-welcome.png',
          dpr,
        );
        await tester.tap(find.byKey(const Key('onboardingContinueButton')));
        await tester.pumpAndSettle();
        expect(find.text('Try one sample card'), findsOneWidget);
        await _capture(
          tester,
          '${(captureIndex++).toString().padLeft(2, '0')}-${id.storageId}-practice.png',
          dpr,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        introController.dispose();

        final markedSample = DemoFixtures.items.first;
        final deckGateway = FakeSiftGateway()
          ..saved = ReviewState.initial()
              .withDemoMode(true)
              .decide(markedSample, ReviewDecision.mark)
              .copyWith(onboardingComplete: true, themeId: id);
        final deckController = SiftController(deckGateway);
        await deckController.initialize();
        await _pumpSiftApp(tester, deckController, '${id.storageId}-deck');
        expect(find.byKey(const Key('swipeCardGesture')), findsOneWidget);
        await _capture(
          tester,
          '${(captureIndex++).toString().padLeft(2, '0')}-${id.storageId}-deck.png',
          dpr,
        );
        await tester.tap(find.byKey(const Key('markedReviewButton')));
        await tester.pumpAndSettle();
        expect(find.text('Marked photos'), findsOneWidget);
        await _capture(
          tester,
          '${(captureIndex++).toString().padLeft(2, '0')}-${id.storageId}-marked.png',
          dpr,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('photoOptionsButton')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('How Hirang works'));
        await tester.pumpAndSettle();
        expect(find.text('How Hirang works'), findsOneWidget);
        await _capture(
          tester,
          '${(captureIndex++).toString().padLeft(2, '0')}-${id.storageId}-help-dialog.png',
          dpr,
        );
        await tester.tap(find.text('Got it'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('photoOptionsButton')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('internalSettingsMenuItem')));
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsOneWidget);
        await _capture(
          tester,
          '${(captureIndex++).toString().padLeft(2, '0')}-${id.storageId}-settings.png',
          dpr,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        deckController.dispose();

        final errorGateway = FakeSiftGateway()
          ..access = const PhotoAccess(status: 'full', sdkInt: 36)
          ..photos = const [_fixture]
          ..thumbnailData = marketFixture
          ..saved = ReviewState.initial().copyWith(
            onboardingComplete: true,
            themeId: id,
          );
        final errorController = SiftController(errorGateway);
        await errorController.initialize();
        errorGateway.queryException = StateError('generated query failure');
        await errorController.refreshFromSystem();
        expect(errorController.error, contains('could not refresh'));
        await _pumpSiftApp(tester, errorController, '${id.storageId}-error');
        await _settleImages(tester);
        expect(
          find.textContaining('could not refresh your local photo library'),
          findsOneWidget,
        );
        await _capture(
          tester,
          '${(captureIndex++).toString().padLeft(2, '0')}-${id.storageId}-query-error.png',
          dpr,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        errorController.dispose();

        final confirmGateway = FakeSiftGateway()
          ..access = const PhotoAccess(status: 'full', sdkInt: 36)
          ..photos = const [_fixture, _fixtureSecond]
          ..thumbnailData = marketFixture
          ..saved = ReviewState.initial()
              .decide(_fixture, ReviewDecision.mark)
              .decide(_fixtureSecond, ReviewDecision.mark)
              .copyWith(onboardingComplete: true, themeId: id);
        final confirmController = SiftController(confirmGateway);
        await confirmController.initialize();
        PhotoArtwork.invalidateAll();
        await _pumpSiftApp(
          tester,
          confirmController,
          '${id.storageId}-trash-confirmation',
        );
        await tester.tap(find.byKey(const Key('markedReviewButton')));
        await _settleImages(tester);
        await tester.pumpAndSettle();
        expect(find.byType(MarkedReviewScreen), findsOneWidget);
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
          find.textContaining('2 marked photos are selected'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Photos are not moved to trash until you approve it.',
          ),
          findsOneWidget,
        );
        expect(confirmGateway.beginCalls, 0);
        await tester.pump(const Duration(milliseconds: 350));
        await _capture(
          tester,
          '${(captureIndex++).toString().padLeft(2, '0')}-${id.storageId}-trash-confirmation.png',
          dpr,
        );
        expect(confirmGateway.beginCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        confirmController.dispose();
      }
    },
  );
}

Future<void> _pumpSiftApp(
  WidgetTester tester,
  SiftController controller,
  String key,
) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('visualCaptureBoundary'),
      child: SiftApp(key: ValueKey<String>(key), controller: controller),
    ),
  );
  await _settleImages(tester);
  await tester.pumpAndSettle();
}

Future<void> _loadRenderFonts() async {
  const root = '/home/francisgiann/flutter/bin/cache/artifacts/material_fonts';
  for (final (family, file) in [
    ('Roboto', '$root/Roboto-Regular.ttf'),
    ('MaterialIcons', '$root/MaterialIcons-Regular.otf'),
  ]) {
    final bytes = File(file).readAsBytesSync();
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}

Future<double> _configure(
  WidgetTester tester,
  Size logicalSize, {
  required double scale,
  Brightness brightness = Brightness.light,
  double dpr = 2,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(
    logicalSize.width * dpr,
    logicalSize.height * dpr,
  );
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  return dpr;
}

Future<void> _pump(WidgetTester tester, Widget home) => tester.pumpWidget(
  RepaintBoundary(
    key: const Key('visualCaptureBoundary'),
    child: MaterialApp(
      key: UniqueKey(),
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: buildHirangTheme(Brightness.light),
      darkTheme: buildHirangTheme(Brightness.dark),
      home: home,
    ),
  ),
);

Future<void> _capture(WidgetTester tester, String name, double dpr) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('visualCaptureBoundary')),
  );
  final bytes = await tester.runAsync<Uint8List>(() async {
    final image = await boundary.toImage(pixelRatio: dpr);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('PNG encoding failed for $name');
    final file = File('build/visual-review/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return data.buffer.asUint8List();
  });
  if (bytes == null || bytes.isEmpty) {
    throw StateError('Flutter test I/O did not complete for $name');
  }
  debugPrint(
    'VISUAL_CAPTURED: build/visual-review/$name (${bytes.length} bytes)',
  );
}

Future<Uint8List> _generatedFixturePng() async =>
    File('test/fixtures/market_generated.png').readAsBytesSync();

Future<void> _settleImages(WidgetTester tester) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    await tester.pump();
    final providers = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .toSet();
    await tester.runAsync(() async {
      for (final provider in providers) {
        final stream = provider.resolve(ImageConfiguration.empty);
        final completed = Completer<void>();
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (image, _) {
            if (!completed.isCompleted) completed.complete();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              stream.removeListener(listener);
              image.dispose();
            });
          },
          onError: (Object _, StackTrace? _) {
            stream.removeListener(listener);
            if (!completed.isCompleted) completed.complete();
          },
        );
        stream.addListener(listener);
        await completed.future.timeout(const Duration(seconds: 5));
      }
    });
    await tester.pump(const Duration(milliseconds: 80));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
}

Future<PhotoImageData?> _boundedDetailFixture(
  PhotoAsset item,
  int requestedEdge,
  bool sourceDetail,
) async {
  final edge = requestedEdge.clamp(512, 2048).toInt();
  if (edge % 64 != 0) {
    throw StateError('Fixture edge must use the production 64px bucket.');
  }
  const sourceWidth = 1800;
  const sourceHeight = 2700;
  final sourceArea = sourceWidth * sourceHeight;
  final scale = math.min(
    1.0,
    math.min(
      edge / math.max(sourceWidth, sourceHeight),
      math.sqrt(3000000 / sourceArea),
    ),
  );
  final width = math.max(1, (sourceWidth * scale).floor()).toInt();
  final height = math.max(1, (sourceHeight * scale).floor()).toInt();
  final bytes = File('test/fixtures/detail_bounded/edge_$edge.png')
      .readAsBytesSync();
  return PhotoImageData(
    bytes: bytes,
    width: width,
    height: height,
    isSourceDetail: sourceDetail,
  );
}
