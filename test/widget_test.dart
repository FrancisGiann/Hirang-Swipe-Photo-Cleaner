import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hirang/data/demo_fixtures.dart';
import 'package:hirang/app/sift_controller.dart';
import 'package:hirang/app/hirang_theme.dart';
import 'package:hirang/domain/review_state.dart';
import 'package:hirang/platform/sift_gateway.dart';
import 'package:hirang/main.dart';
import 'package:hirang/ui/marked_review_screen.dart';
import 'package:hirang/ui/sift_home.dart';

import 'support/fake_sift_gateway.dart';

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
