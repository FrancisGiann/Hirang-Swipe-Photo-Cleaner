import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Hirang's overlapping photo cards, peeled corner, and exposed sparkle.
///
/// The public size/API stays shared by the toolbar and onboarding surfaces.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _BrandMarkPainter(
          ink: colors.primary,
          paper: colors.surface,
          backCard: colors.secondary,
          window: colors.surfaceContainerHighest,
          fold: colors.tertiaryContainer,
          photoAccent: colors.tertiary,
          sparkle: const Color(0xFFD99155),
        ),
      ),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter({
    required this.ink,
    required this.paper,
    required this.backCard,
    required this.window,
    required this.fold,
    required this.photoAccent,
    required this.sparkle,
  });

  final Color ink;
  final Color paper;
  final Color backCard;
  final Color window;
  final Color fold;
  final Color photoAccent;
  final Color sparkle;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // The artwork occupies approximately 64 × 64 units in the 100 × 100
    // master. Fit that geometry to 90% of the allocated square so the mark
    // remains optically full-size without clipping its rotated rear card.
    final scale = math.min(size.width, size.height) * .90 / 64;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-50, -50);

    canvas.save();
    canvas.translate(47, 50.5);
    canvas.rotate(-11 * math.pi / 180);
    canvas.translate(-47, -50.5);
    final rear = RRect.fromRectAndRadius(
      const Rect.fromLTWH(26, 24, 42, 53),
      const Radius.circular(8),
    );
    canvas.drawRRect(rear, Paint()..color = backCard);
    canvas.drawRRect(
      rear,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.2,
    );
    canvas.restore();

    final star = Path()
      ..moveTo(74, 67)
      ..lineTo(76, 72)
      ..lineTo(80, 74)
      ..lineTo(76, 76)
      ..lineTo(74, 80)
      ..lineTo(72, 76)
      ..lineTo(68, 74)
      ..lineTo(72, 72)
      ..close();
    canvas.drawPath(star, Paint()..color = sparkle);

    final front = Path()
      ..moveTo(46, 27)
      ..lineTo(70, 27)
      ..quadraticBezierTo(77, 27, 77, 34)
      ..lineTo(77, 60)
      ..lineTo(60, 77)
      ..lineTo(46, 77)
      ..quadraticBezierTo(40, 77, 40, 71)
      ..lineTo(40, 34)
      ..quadraticBezierTo(40, 27, 46, 27)
      ..close();
    canvas.drawPath(front, Paint()..color = paper);
    canvas.drawPath(
      front,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.2
        ..strokeJoin = StrokeJoin.round,
    );

    final photoWindow = RRect.fromRectAndRadius(
      const Rect.fromLTWH(46, 36, 24, 19),
      const Radius.circular(3.5),
    );
    canvas.drawRRect(photoWindow, Paint()..color = window);
    canvas.drawRRect(
      photoWindow,
      Paint()
        ..color = fold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(48, 38, 8, 15),
        const Radius.circular(2),
      ),
      Paint()..color = backCard,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(58, 38, 10, 6),
        const Radius.circular(1.6),
      ),
      Paint()..color = sparkle,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(58, 47, 10, 6),
        const Radius.circular(1.6),
      ),
      Paint()..color = photoAccent,
    );

    final peel = Path()
      ..moveTo(60, 76)
      ..lineTo(60, 63)
      ..quadraticBezierTo(60, 60, 63, 60)
      ..lineTo(77, 60)
      ..close();
    canvas.drawPath(peel, Paint()..color = fold);
    canvas.drawLine(
      const Offset(63, 62),
      const Offset(75, 62),
      Paint()
        ..color = ink.withValues(alpha: .38)
        ..strokeWidth = 1.9
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BrandMarkPainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.paper != paper ||
      oldDelegate.backCard != backCard ||
      oldDelegate.window != window ||
      oldDelegate.fold != fold ||
      oldDelegate.photoAccent != photoAccent ||
      oldDelegate.sparkle != sparkle;
}
