import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hirang/app/hirang_theme.dart';
import 'package:hirang/app/sift_controller.dart';
import 'package:hirang/data/demo_fixtures.dart';
import 'package:hirang/domain/hirang_theme_id.dart';
import 'package:hirang/domain/review_state.dart';
import 'package:hirang/main.dart';

import 'support/fake_sift_gateway.dart';

void main() {
  test('theme IDs migrate additively and unknown values safely use Amihan', () {
    final legacy = ReviewState.decode(
      '{"version":1,"demoMode":false,"onboardingComplete":true,'
      '"decisions":{"legacy-photo":"keep"}}',
    );
    expect(legacy.themeId, HirangThemeId.amihan);
    expect(legacy.decisions['legacy-photo'], ReviewDecision.keep);

    final unknown = ReviewState.decode(
      '{"version":1,"themeId":"unrecognized-palette",'
      '"decisions":{"kept":"keep"}}',
    );
    expect(unknown.themeId, HirangThemeId.amihan);
    expect(unknown.decisions['kept'], ReviewDecision.keep);

    final saved = unknown.copyWith(themeId: HirangThemeId.dapithapon);
    final restored = ReviewState.decode(saved.encode());
    expect(restored.themeId, HirangThemeId.dapithapon);
    expect(restored.decisions, unknown.decisions);
  });

  test('theme writes preserve review decisions and a failed save keeps the prior theme', () async {
    final keptPhoto = DemoFixtures.items.first;
    final gateway = FakeSiftGateway()
      ..saved = ReviewState.initial()
          .withDemoMode(true)
          .decide(keptPhoto, ReviewDecision.keep)
          .copyWith(onboardingComplete: true);
    final controller = SiftController(gateway);
    await controller.initialize();

    expect(await controller.selectTheme(HirangThemeId.dapithapon), isTrue);
    expect(controller.state.themeId, HirangThemeId.dapithapon);
    expect(controller.state.decisions[keptPhoto.id], ReviewDecision.keep);
    expect(gateway.saved.themeId, HirangThemeId.dapithapon);

    gateway.saveException = StateError('fixture write failure');
    expect(await controller.selectTheme(HirangThemeId.hatinggabi), isFalse);
    expect(controller.state.themeId, HirangThemeId.dapithapon);
    expect(controller.themeSelection.value, HirangThemeId.dapithapon);
    expect(gateway.saved.decisions[keptPhoto.id], ReviewDecision.keep);
    expect(controller.error, contains('Appearance could not be saved'));

    gateway.saveException = null;
    final restarted = SiftController(gateway);
    await restarted.initialize();
    expect(restarted.state.themeId, HirangThemeId.dapithapon);
    expect(restarted.state.decisions[keptPhoto.id], ReviewDecision.keep);
    controller.dispose();
    restarted.dispose();
  });

  test('serialized theme and review writes preserve both changes', () async {
    final gateway = FakeSiftGateway()
      ..saved = ReviewState.initial().withDemoMode(true);
    final controller = SiftController(gateway);
    await controller.initialize();
    final saveGate = Completer<void>();
    gateway.saveCompleter = saveGate;

    final themeWrite = controller.selectTheme(HirangThemeId.dapithapon);
    await Future<void>.delayed(Duration.zero);
    final decisionWrite = controller.decide(
      DemoFixtures.items.first,
      ReviewDecision.keep,
    );
    await Future<void>.delayed(Duration.zero);
    expect(gateway.saveCalls, 1);

    saveGate.complete();
    expect(await themeWrite, isTrue);
    expect(await decisionWrite, isTrue);
    expect(controller.state.themeId, HirangThemeId.dapithapon);
    expect(
      controller.state.decisions[DemoFixtures.items.first.id],
      ReviewDecision.keep,
    );
    expect(gateway.saved.themeId, HirangThemeId.dapithapon);
    expect(
      gateway.saved.decisions[DemoFixtures.items.first.id],
      ReviewDecision.keep,
    );
    controller.dispose();
  });

  test('shared text and action colors meet contrast in every theme', () {
    for (final id in HirangThemeId.values) {
      final theme = buildHirangThemeFor(id);
      final scheme = theme.colorScheme;
      final semantic = theme.extension<HirangSemanticColors>()!;
      final pairs = <(String, Color, Color)>[
        ('onSurface / surface', scheme.onSurface, scheme.surface),
        (
          'onSurface / scaffold',
          scheme.onSurface,
          theme.scaffoldBackgroundColor,
        ),
        ('onSurfaceVariant / surface', scheme.onSurfaceVariant, scheme.surface),
        (
          'onSurfaceVariant / scaffold',
          scheme.onSurfaceVariant,
          theme.scaffoldBackgroundColor,
        ),
        ('primary / surface', scheme.primary, scheme.surface),
        ('primary / scaffold', scheme.primary, theme.scaffoldBackgroundColor),
        ('onPrimary / primary', scheme.onPrimary, scheme.primary),
        ('onSecondary / secondary', scheme.onSecondary, scheme.secondary),
        ('onTertiary / tertiary', scheme.onTertiary, scheme.tertiary),
        ('error / surface', scheme.error, scheme.surface),
        (
          'primary / secondaryContainer',
          scheme.primary,
          scheme.secondaryContainer,
        ),
        (
          'onPrimaryContainer / primaryContainer',
          scheme.onPrimaryContainer,
          scheme.primaryContainer,
        ),
        (
          'onSecondaryContainer / secondaryContainer',
          scheme.onSecondaryContainer,
          scheme.secondaryContainer,
        ),
        (
          'onTertiaryContainer / tertiaryContainer',
          scheme.onTertiaryContainer,
          scheme.tertiaryContainer,
        ),
        (
          'onErrorContainer / errorContainer',
          scheme.onErrorContainer,
          scheme.errorContainer,
        ),
        ('Keep label', semantic.keepForeground, semantic.keepBackground),
        ('Mark label', semantic.markForeground, semantic.markBackground),
      ];
      for (final (label, foreground, background) in pairs) {
        expect(
          _contrast(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: '${id.label}: $label',
        );
      }
    }
  });

  testWidgets(
    'live Settings picker switches all palettes without resetting the deck',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 886);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final first = DemoFixtures.items.first;
      final gateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withDemoMode(true)
            .decide(first, ReviewDecision.mark)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(SiftApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('swipeCardGesture')), findsOneWidget);

      await tester.tap(find.byKey(const Key('photoOptionsButton')));
      await tester.pumpAndSettle();
      expect(find.text('Android app settings'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);

      for (final id in HirangThemeId.values) {
        await tester.tap(find.byKey(Key('themeOption-${id.storageId}')));
        await tester.pumpAndSettle();
        expect(controller.state.themeId, id);
        expect(gateway.saved.themeId, id);
        final app = tester.widget<MaterialApp>(
          find.byKey(const ValueKey('hirangMaterialApp')),
        );
        expect(app.themeMode, id.isDark ? ThemeMode.dark : ThemeMode.light);
        expect(app.themeAnimationDuration, Duration.zero);
      }

      expect(controller.state.decisions[first.id], ReviewDecision.mark);
      expect(
        find.byKey(Key('themeOption-${controller.state.themeId.storageId}')),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('swipeCardGesture')), findsOneWidget);
      expect(controller.state.decisions[first.id], ReviewDecision.mark);

      final restarted = SiftController(gateway);
      await restarted.initialize();
      expect(restarted.state.themeId, HirangThemeId.hatinggabi);
      expect(restarted.state.decisions[first.id], ReviewDecision.mark);
      controller.dispose();
      restarted.dispose();
    },
  );

  testWidgets(
    'appearance Settings stays usable with large text on a narrow screen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final gateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withDemoMode(true)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(SiftApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photoOptionsButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byKey(const Key('themeOption-amihan')), findsOneWidget);
      expect(find.byKey(const Key('themeOption-dapithapon')), findsOneWidget);
      expect(find.byKey(const Key('themeOption-hatinggabi')), findsOneWidget);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets(
    'failed theme save is visible and leaves the current palette selected',
    (tester) async {
      final gateway = FakeSiftGateway()
        ..saved = ReviewState.initial()
            .withDemoMode(true)
            .copyWith(onboardingComplete: true);
      final controller = SiftController(gateway);
      await controller.initialize();
      await tester.pumpWidget(SiftApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photoOptionsButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      gateway.saveException = StateError('fixture write failure');
      await tester.tap(find.byKey(const Key('themeOption-hatinggabi')));
      await tester.pumpAndSettle();
      expect(controller.state.themeId, HirangThemeId.amihan);
      expect(gateway.saved.themeId, HirangThemeId.amihan);
      expect(
        find.textContaining('Appearance could not be saved'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<MaterialApp>(
              find.byKey(const ValueKey('hirangMaterialApp')),
            )
            .themeMode,
        ThemeMode.light,
      );
      controller.dispose();
    },
  );
}

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  final lighter = a > b ? a : b;
  final darker = a > b ? b : a;
  return (lighter + .05) / (darker + .05);
}
