import 'dart:async';

import 'package:flutter/material.dart';

import '../app/hirang_theme.dart';
import '../app/sift_controller.dart';
import '../data/demo_fixtures.dart';
import '../domain/review_state.dart';
import 'brand_mark.dart';
import 'photo_art.dart';

/// First-open introduction and a replayable, permission-free sample walkthrough.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.controller,
    this.replay = false,
  });

  final SiftController controller;
  final bool replay;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pages = PageController();
  int _page = 0;
  double _practiceDrag = 0;
  ReviewDecision? _practiceDecision;
  bool _finishing = false;
  bool _pageNavigationBusy = false;
  String? _errorMessage;

  static const int _pageCount = 4;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _finish({
    bool startSample = false,
    bool choosePhotos = false,
  }) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    if (!widget.replay) await widget.controller.completeOnboarding();
    if (!widget.replay && !widget.controller.state.onboardingComplete) {
      if (mounted) {
        setState(() {
          _finishing = false;
          _errorMessage =
              'The introduction could not be saved. Please try again.';
        });
      }
      return;
    }
    if (startSample) await widget.controller.setDemoMode(true);
    if (choosePhotos) await widget.controller.connectLibrary();
    if (widget.replay && mounted) Navigator.of(context).pop();
  }

  void _back() {
    if (_page > 0) {
      unawaited(_moveToPage(_page - 1));
    } else if (widget.replay) {
      Navigator.of(context).maybePop();
    } else {
      // Back on the first-open intro means “not now”; it never requests access.
      _finish();
    }
  }

  Future<void> _moveToPage(int target) async {
    if (_pageNavigationBusy ||
        _finishing ||
        target < 0 ||
        target >= _pageCount) {
      return;
    }
    setState(() => _pageNavigationBusy = true);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion) {
      _pages.jumpToPage(target);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } else {
      await _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
    if (mounted) setState(() => _pageNavigationBusy = false);
  }

  void _practice(ReviewDecision decision) {
    setState(() {
      _practiceDecision = decision;
      _practiceDrag = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme;
    return PopScope<Object?>(
      canPop: widget.replay && _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: _page == 0 ? 'Close introduction' : 'Previous step',
            onPressed: _back,
            icon: Icon(
              _page == 0
                  ? (widget.replay
                        ? Icons.close_rounded
                        : Icons.arrow_back_rounded)
                  : Icons.arrow_back_rounded,
            ),
          ),
          title: Row(
            children: [
              const BrandMark(size: 30),
              const SizedBox(width: 10),
              Text(
                'Hirang',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.3,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: _finishing || _pageNavigationBusy
                  ? null
                  : () => _finish(),
              child: Text(widget.replay ? 'Done' : 'Skip'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Row(
                  children: List.generate(
                    _pageCount,
                    (index) => Expanded(
                      child: AnimatedContainer(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        height: 3,
                        margin: EdgeInsets.only(
                          right: index == _pageCount - 1 ? 0 : 6,
                        ),
                        decoration: BoxDecoration(
                          color: index <= _page
                              ? color.primary
                              : color.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Material(
                    key: const Key('onboardingSaveError'),
                    color: color.errorContainer,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: color.onErrorContainer),
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (page) => setState(() => _page = page),
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _WelcomePage(colors: color),
                    _PracticePage(
                      decision: _practiceDecision,
                      offset: _practiceDrag,
                      onDragUpdate: (delta) => setState(
                        () => _practiceDrag = (_practiceDrag + delta).clamp(
                          -120,
                          120,
                        ),
                      ),
                      onDragEnd: () {
                        if (_practiceDrag.abs() > 42) {
                          _practice(
                            _practiceDrag < 0
                                ? ReviewDecision.mark
                                : ReviewDecision.keep,
                          );
                        } else {
                          setState(() => _practiceDrag = 0);
                        }
                      },
                      onDecision: _practice,
                      onReset: () => setState(() {
                        _practiceDecision = null;
                        _practiceDrag = 0;
                      }),
                    ),
                    _TrashExplanationPage(colors: color),
                    _ChoosePhotosPage(
                      finishing: _finishing,
                      onChoosePhotos: () => _finish(choosePhotos: true),
                      onTrySample: () => _finish(startSample: true),
                      onLater: () => _finish(),
                    ),
                  ],
                ),
              ),
              if (_page < _pageCount - 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _pageNavigationBusy || _finishing
                          ? null
                          : () => unawaited(_moveToPage(_page + 1)),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 54),
                      ),
                      key: const Key('onboardingContinueButton'),
                      child: const Text('Continue'),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
                  child: Text(
                    'No permission is requested until you choose photos.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: color.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.colors});
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => _IntroPage(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const BrandMark(size: 94),
        const SizedBox(height: 28),
        Text(
          'A calmer way to review your photos.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.6),
        ),
        const SizedBox(height: 14),
        Text(
          'Keep the moments you want. Mark the ones you may want to move to system trash later.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
        ),
        const SizedBox(height: 28),
        _PrivacyNote(colors: colors),
      ],
    ),
  );
}

class _PracticePage extends StatelessWidget {
  const _PracticePage({
    required this.decision,
    required this.offset,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDecision,
    required this.onReset,
  });

  final ReviewDecision? decision;
  final double offset;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final ValueChanged<ReviewDecision> onDecision;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sample = DemoFixtures.items[1];
    final semantic = theme.extension<HirangSemanticColors>()!;
    ButtonStyle decisionButtonStyle(Color background, Color foreground) =>
        FilledButton.styleFrom(
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          backgroundColor: background,
          foregroundColor: foreground,
        );
    final response = switch (decision) {
      ReviewDecision.mark => 'Marked for review. The sample stays unchanged.',
      ReviewDecision.keep => 'Kept on this sample deck.',
      null => 'Try a swipe or choose a button. This is generated sample art.',
    };
    return _IntroPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Try one sample card',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'This practice uses fictional art and never touches your library.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          AspectRatio(
            aspectRatio: 1.24,
            child: Semantics(
              label: 'Generated practice photo: ${sample.title}',
              hint: 'Swipe left to mark or right to keep.',
              child: GestureDetector(
                key: const Key('onboardingPracticeCard'),
                onHorizontalDragUpdate: (details) =>
                    onDragUpdate(details.delta.dx),
                onHorizontalDragEnd: (_) => onDragEnd(),
                child: Transform.translate(
                  offset: Offset(offset, 0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: DemoArtwork(
                      index: sample.demoIndex ?? 0,
                      title: sample.title,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(response, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('practiceMarkButton'),
                  onPressed: () => onDecision(ReviewDecision.mark),
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Mark'),
                  style: decisionButtonStyle(
                    semantic.markBackground,
                    semantic.markForeground,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('practiceKeepButton'),
                  onPressed: () => onDecision(ReviewDecision.keep),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Keep'),
                  style: decisionButtonStyle(
                    semantic.keepBackground,
                    semantic.keepForeground,
                  ),
                ),
              ),
            ],
          ),
          if (decision != null)
            Center(
              child: TextButton.icon(
                key: const Key('practiceUndoButton'),
                onPressed: onReset,
                icon: const Icon(Icons.undo_rounded),
                label: const Text('Undo practice'),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrashExplanationPage extends StatelessWidget {
  const _TrashExplanationPage({required this.colors});
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => _IntroPage(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Mark is not trash',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.5),
        ),
        const SizedBox(height: 10),
        Text(
          'Nothing changes when you mark a photo. You review that list later, then confirm the batch in Hirang and again in Android.',
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(height: 1.45, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        const _SafetyPoint(
          icon: Icons.bookmark_outline_rounded,
          title: 'Mark to decide later',
          detail: 'Marking only adds the photo to your local review list.',
        ),
        const SizedBox(height: 14),
        const _SafetyPoint(
          icon: Icons.verified_user_outlined,
          title: 'Two deliberate confirmations',
          detail: 'Hirang rechecks exact photos. Android asks before recoverable system trash.',
        ),
        const SizedBox(height: 14),
        const _SafetyPoint(
          icon: Icons.restore_rounded,
          title: 'Recovery and space depend on Android',
          detail: 'Trash may expire. Recovery uses a gallery’s supported trash view, and storage may not free immediately.',
        ),
      ],
    ),
  );
}

class _ChoosePhotosPage extends StatelessWidget {
  const _ChoosePhotosPage({
    required this.finishing,
    required this.onChoosePhotos,
    required this.onTrySample,
    required this.onLater,
  });

  final bool finishing;
  final VoidCallback onChoosePhotos;
  final VoidCallback onTrySample;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) => _IntroPage(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choose your next step',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.5),
        ),
        const SizedBox(height: 10),
        Text(
          'Hirang only asks for photo access after you choose to connect your local library. On Android 14 and newer, you can choose selected photos when Android offers that option; choices vary by version.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45),
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          key: const Key('onboardingChoosePhotos'),
          onPressed: finishing ? null : onChoosePhotos,
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Choose local photos'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('onboardingTrySample'),
          onPressed: finishing ? null : onTrySample,
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Start with the sample deck'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 54)),
        ),
        TextButton(
          key: const Key('onboardingLater'),
          onPressed: finishing ? null : onLater,
          child: const Text('Maybe later'),
        ),
      ],
    ),
  );
}

class _IntroPage extends StatelessWidget {
  const _IntroPage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight - 52),
        child: child,
      ),
    ),
  );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.colors});
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      children: [
        Icon(Icons.phonelink_lock_outlined, color: colors.primary),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'Private by design. Photos and review progress stay on this device; nothing is uploaded.',
          ),
        ),
      ],
    ),
  );
}

class _SafetyPoint extends StatelessWidget {
  const _SafetyPoint({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Theme.of(context).colorScheme.primary),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(
              detail,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
