import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/review_state.dart';
import '../platform/sift_gateway.dart';
import 'photo_art.dart';

/// Selects a bounded source-detail request for the current viewport.
///
/// The native loader caps source images at 2048 px. Keeping this bucketed
/// prevents cache churn during layout changes while avoiding a 512 px grid
/// thumbnail as the final full-screen image.
int photoImageTargetEdge(Size viewport, double devicePixelRatio) {
  if (!viewport.width.isFinite || !viewport.height.isFinite) return 512;
  final physicalEdge =
      math.max(viewport.width, viewport.height) * devicePixelRatio;
  return (((physicalEdge / 64).ceil()) * 64).clamp(512, 2048).toInt();
}

Future<void> showPhotoFullscreen(
  BuildContext context, {
  required PhotoAsset item,
  required bool demoMode,
  required SiftGateway gateway,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      PhotoFullscreenViewer(item: item, demoMode: demoMode, gateway: gateway),
);

/// Full-screen, read-only photo inspection shared by Home and Marked Photos.
class PhotoFullscreenViewer extends StatefulWidget {
  const PhotoFullscreenViewer({
    super.key,
    required this.item,
    required this.demoMode,
    required this.gateway,
  });

  final PhotoAsset item;
  final bool demoMode;
  final SiftGateway gateway;

  @override
  State<PhotoFullscreenViewer> createState() => _PhotoFullscreenViewerState();
}

class _PhotoFullscreenViewerState extends State<PhotoFullscreenViewer> {
  late final TransformationController _transformation =
      TransformationController();

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          key: const Key('closePhotoViewer'),
          tooltip: 'Close photo viewer',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: LayoutBuilder(
                    builder: (context, constraints) => InteractiveViewer(
                      key: const Key('photoViewerInteraction'),
                      transformationController: _transformation,
                      minScale: 1,
                      maxScale: 4,
                      boundaryMargin: const EdgeInsets.all(40),
                      child: SizedBox.expand(
                        child: PhotoArtwork(
                          item: widget.item,
                          demoMode: widget.demoMode,
                          gateway: widget.gateway,
                          fit: BoxFit.contain,
                          maxEdge: photoImageTargetEdge(
                            constraints.biggest,
                            MediaQuery.devicePixelRatioOf(context),
                          ),
                          preferSourceDetail: !widget.demoMode,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                widget.demoMode
                    ? 'Generated sample · no library photo is used'
                    : 'Private preview · image stays on this device',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
