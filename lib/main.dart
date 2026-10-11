import 'package:flutter/material.dart';

import 'app/brand.dart';
import 'app/hirang_theme.dart';
import 'app/sift_controller.dart';
import 'domain/hirang_theme_id.dart';
import 'platform/sift_gateway.dart';
import 'ui/sift_home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 * 1024 * 1024;
  runApp(SiftApp(controller: SiftController(PlatformSiftGateway())));
}

class SiftApp extends StatelessWidget {
  const SiftApp({super.key, required this.controller});

  final SiftController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<HirangThemeId>(
    valueListenable: controller.themeSelection,
    builder: (context, selectedTheme, _) {
      final selectedBrightness = selectedTheme.isDark;
      return MaterialApp(
        key: const ValueKey('hirangMaterialApp'),
        title: appDisplayName,
        debugShowCheckedModeBanner: false,
        navigatorObservers: [photoRouteObserver],
        themeAnimationDuration: Duration.zero,
        themeMode: selectedBrightness ? ThemeMode.dark : ThemeMode.light,
        theme: buildHirangThemeFor(
          selectedBrightness ? HirangThemeId.amihan : selectedTheme,
        ),
        darkTheme: buildHirangThemeFor(HirangThemeId.hatinggabi),
        home: SiftHome(controller: controller),
      );
    },
  );
}

ThemeData buildHirangTheme(Brightness brightness) => buildHirangThemeFor(
  brightness == Brightness.dark
      ? HirangThemeId.hatinggabi
      : HirangThemeId.amihan,
);
