import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hirang/data/demo_fixtures.dart';
import 'package:hirang/app/sift_controller.dart';
import 'package:hirang/domain/review_state.dart';
import 'package:hirang/platform/sift_gateway.dart';
import 'package:hirang/main.dart';
import 'package:hirang/ui/onboarding_screen.dart';
import 'package:hirang/ui/sift_home.dart';

import 'support/fake_sift_gateway.dart';

void main() {
  testWidgets(
    'unread saved state blocks onboarding writes and permissions until retry',
    (tester) async {
      final original = ReviewState.initial()
          .withDemoMode(true)
          .decide(DemoFixtures.items.first, ReviewDecision.keep);
      final gateway = FakeSiftGateway()
        ..saved = original
        ..loadException = StateError('temporary read failure');
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
      expect(controller.stateLoaded, isFalse);
      expect(find.byKey(const Key('retrySavedStateButton')), findsOneWidget);
      expect(find.byType(OnboardingScreen), findsNothing);

      await controller.completeOnboarding();
      await controller.setDemoMode(false);
      await controller.connectLibrary();
      expect(gateway.permissionRequests, 0);
      expect(gateway.saveCalls, 0);
      expect(gateway.saved.encode(), original.encode());

      gateway.loadException = null;
      await tester.tap(find.byKey(const Key('retrySavedStateButton')));
      await tester.pumpAndSettle();
      expect(controller.stateLoaded, isTrue);
      expect(controller.state.decisions, original.decisions);
      expect(find.byType(OnboardingScreen), findsOneWidget);

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(controller.state.onboardingComplete, isTrue);
      expect(controller.state.decisions, original.decisions);
      expect(gateway.permissionRequests, 0);
    },
  );

  testWidgets(
    'native journal read failure blocks trash work until retry recovers the old operation',
    (tester) async {
      final photo = realPhoto('native-journal-locked');
      final original = ReviewState.initial().decide(photo, ReviewDecision.mark);
      final oldNativeOperation = TrashOperation(
        id: 'previous-native-operation',
        createdAtMillis: 1,
        items: [photo],
        outcomes: {photo.id: OperationItemOutcome.unknown},
        status: 'needsContinue',
      );
      final gateway = FakeSiftGateway()
        ..saved = original
        ..access = const PhotoAccess(status: 'full', sdkInt: 36)
        ..photos = [photo]
        ..operation = oldNativeOperation
        ..readException = StateError('temporary journal read failure');
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
      expect(controller.stateLoaded, isTrue);
      expect(controller.startupReady, isFalse);
      expect(find.byKey(const Key('retrySavedStateButton')), findsOneWidget);
      await controller.beginTrash(expectedItemIds: [photo.id]);
      expect(await controller.decide(photo, ReviewDecision.keep), isFalse);
      await controller.setFilters(const ReviewFilters(screenshotsOnly: true));
      expect(gateway.beginCalls, 0);
      expect(gateway.saveCalls, 0);
      expect(gateway.saved.operation, isNull);

      gateway.readException = null;
      await tester.tap(find.byKey(const Key('retrySavedStateButton')));
      await tester.pumpAndSettle();
      expect(controller.startupReady, isTrue);
      expect(controller.state.operation?.id, oldNativeOperation.id);
      expect(controller.state.operation?.status, 'needsContinue');
      expect(controller.state.decisions[photo.id], ReviewDecision.mark);
      expect(gateway.beginCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed first-run completion stays visible and can be retried', (
    tester,
  ) async {
    final gateway = FakeSiftGateway()
      ..saved = ReviewState.initial()
      ..saveException = StateError('temporary write failure');
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

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(controller.state.onboardingComplete, isFalse);
    expect(find.byKey(const Key('onboardingSaveError')), findsOneWidget);
    expect(gateway.permissionRequests, 0);

    gateway.saveException = null;
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(controller.state.onboardingComplete, isTrue);
    expect(find.byType(OnboardingScreen), findsNothing);
  });

  testWidgets('replaying the introduction does not save or alter decisions', (
    tester,
  ) async {
    final original = ReviewState.initial()
        .withDemoMode(true)
        .decide(DemoFixtures.items.first, ReviewDecision.mark)
        .copyWith(onboardingComplete: true);
    final gateway = FakeSiftGateway()..saved = original;
    final controller = SiftController(gateway);
    await controller.initialize();
    final writesBeforeReplay = gateway.saveCalls;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHirangTheme(Brightness.light),
        darkTheme: buildHirangTheme(Brightness.dark),
        home: OnboardingScreen(controller: controller, replay: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(gateway.saveCalls, writesBeforeReplay);
    expect(controller.state.decisions, original.decisions);
    expect(controller.state.undoHistory, original.undoHistory);
    expect(gateway.permissionRequests, 0);
  });

  testWidgets('reduced-motion tutorial guards rapid Continue taps', (
    tester,
  ) async {
    final gateway = FakeSiftGateway()..saved = ReviewState.initial();
    final controller = SiftController(gateway);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHirangTheme(Brightness.light),
        darkTheme: buildHirangTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SiftHome(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final next = find.byKey(const Key('onboardingContinueButton'));
    await tester.tap(next);
    await tester.pump();
    expect(find.text('Try one sample card'), findsOneWidget);
    expect(find.text('Mark is not trash'), findsNothing);
    expect(tester.widget<FilledButton>(next).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 301));
  });
}
