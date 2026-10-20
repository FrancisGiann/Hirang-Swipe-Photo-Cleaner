import 'package:flutter/services.dart';

import '../app/brand.dart';
import '../domain/review_state.dart';

enum PhotoQueryMode { recent, largestKnown, unknownSize, screenshotHints }

bool photoMatchesQueryMode(PhotoQueryMode mode, PhotoAsset item) =>
    switch (mode) {
      PhotoQueryMode.recent => true,
      PhotoQueryMode.largestKnown => item.knownSizeBytes != null,
      PhotoQueryMode.unknownSize => item.knownSizeBytes == null,
      PhotoQueryMode.screenshotHints => item.screenshotHeuristic,
    };

class PhotoPage {
  const PhotoPage({
    required this.items,
    required this.status,
    this.cursor,
    this.hasMore = false,
    this.message,
  });

  final List<PhotoAsset> items;
  final String status;
  final String? cursor;
  final bool hasMore;
  final String? message;

  bool get isSupported => status == 'ready' || status == 'partial';
  bool get isPartial => status == 'partial';
}

/// Optional paging capability. Keeping this separate lets demo and external
/// gateway implementations retain the original SiftGateway contract.
abstract interface class PagedPhotoGateway {
  Future<PhotoPage> queryPhotoPage({
    required PhotoQueryMode mode,
    required int pageSize,
    String? cursor,
    ReviewFilters filters = const ReviewFilters(),
  });
}

class PhotoAccess {
  const PhotoAccess({required this.status, required this.sdkInt});

  final String status;
  final int sdkInt;

  bool get canRead => status == 'full' || status == 'limited';
  bool get isLimited => status == 'limited';
  String get label => switch (status) {
    'full' => 'Full photo access',
    'limited' => 'Selected photo access',
    'unsupported' => 'Android 11 or later is required',
    _ => 'Photo access is off',
  };

  factory PhotoAccess.fromMap(Map<Object?, Object?>? map) => PhotoAccess(
    status: map?['status'] as String? ?? 'denied',
    sdkInt: (map?['sdkInt'] as num?)?.toInt() ?? 0,
  );
}

class PhotoImageData {
  const PhotoImageData({
    required this.bytes,
    required this.width,
    required this.height,
    required this.isSourceDetail,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  /// False means Android could provide only a smaller provider-generated preview.
  final bool isSourceDetail;
}

class Revalidation {
  const Revalidation({required this.id, required this.status});

  final String id;
  final String status;
  bool get isPresent => status == 'present';
  bool get isCertain => status == 'present' || status == 'trashed';
}

abstract interface class SiftGateway {
  Future<ReviewState> loadState();
  Future<void> saveState(ReviewState state);
  Future<PhotoAccess> permissionStatus();
  Future<PhotoAccess> requestPhotoAccess();
  Future<void> openAppSettings();
  Future<List<PhotoAsset>> queryPhotos();
  Future<PhotoImageData?> loadPhotoImage(
    PhotoAsset item, {
    required int maxEdge,
    bool preferSourceDetail = false,
  });
  Future<List<Revalidation>> revalidate(List<PhotoAsset> items);
  Future<TrashOperation?> beginTrashOperation(TrashOperation operation);
  Future<TrashOperation?> readTrashOperation();
  Future<TrashOperation?> reconcileTrashOperation({
    String? operationId,
    bool afterSystemScreenClosed = false,
  });
  Future<TrashOperation?> continueTrashOperation(String operationId);
  Future<void> clearTrashOperation(String operationId);
}

class PlatformSiftGateway implements SiftGateway, PagedPhotoGateway {
  static const MethodChannel _channel = MethodChannel('app.hirang/media');

  Future<Object?> _invoke(String method, [Map<String, Object?>? arguments]) =>
      _channel.invokeMethod<Object?>(method, arguments);

  @override
  Future<ReviewState> loadState() async =>
      ReviewState.decode(await _invoke('loadReviewState') as String?);

  @override
  Future<void> saveState(ReviewState state) async {
    final result = await _invoke('saveReviewState', {'state': state.encode()});
    if (result != true) {
      throw StateError('$appDisplayName could not save review progress.');
    }
  }

  @override
  Future<PhotoAccess> permissionStatus() async => PhotoAccess.fromMap(
    await _invoke('permissionStatus') as Map<Object?, Object?>?,
  );

  @override
  Future<PhotoAccess> requestPhotoAccess() async => PhotoAccess.fromMap(
    await _invoke('requestPhotoAccess') as Map<Object?, Object?>?,
  );

  @override
  Future<void> openAppSettings() async {
    final result = await _invoke('openAppSettings');
    if (result != true) {
      throw StateError('$appDisplayName could not open Android app settings.');
    }
  }

  @override
  Future<List<PhotoAsset>> queryPhotos() async {
    final response = await _invoke('queryPhotos') as List<Object?>? ?? const [];
    return response
        .whereType<Map<Object?, Object?>>()
        .map((row) => PhotoAsset.fromJson(Map<String, Object?>.from(row)))
        .toList(growable: false);
  }

  @override
  Future<PhotoPage> queryPhotoPage({
    required PhotoQueryMode mode,
    required int pageSize,
    String? cursor,
    ReviewFilters filters = const ReviewFilters(),
  }) async {
    final result = await _invoke('queryPhotoPage', {
      'mode': mode.name,
      'pageSize': pageSize.clamp(1, 80).toInt(),
      'cursor': cursor,
      'filters': filters.toJson(),
    });
    if (result is! Map<Object?, Object?>) {
      return const PhotoPage(items: [], status: 'unsupported');
    }
    final rows = result['items'] as List<Object?>? ?? const [];
    return PhotoPage(
      items: rows
          .whereType<Map<Object?, Object?>>()
          .map((row) => PhotoAsset.fromJson(Map<String, Object?>.from(row)))
          .toList(growable: false),
      status: result['status']?.toString() ?? 'error',
      cursor: result['cursor'] as String?,
      hasMore: result['hasMore'] == true,
      message: result['message']?.toString(),
    );
  }

  @override
  Future<PhotoImageData?> loadPhotoImage(
    PhotoAsset item, {
    required int maxEdge,
    bool preferSourceDetail = false,
  }) async {
    final result = await _invoke('loadThumbnail', {
      'asset': item.toJson(),
      'width': maxEdge,
      'sourceDetail': preferSourceDetail,
    });
    if (result == null) return null;
    if (result is! Map<Object?, Object?>) {
      throw StateError('Android returned an unreadable photo preview.');
    }
    final bytes = result['bytes'];
    final width = result['width'];
    final height = result['height'];
    if (bytes is! Uint8List || width is! num || height is! num) {
      throw StateError('Android returned incomplete photo preview data.');
    }
    return PhotoImageData(
      bytes: bytes,
      width: width.toInt(),
      height: height.toInt(),
      isSourceDetail: result['quality'] == 'source',
    );
  }

  @override
  Future<List<Revalidation>> revalidate(List<PhotoAsset> items) async {
    final response =
        await _invoke('revalidate', {
          'items': items.map((item) => item.toJson()).toList(growable: false),
        }) as List<Object?>? ??
        const [];
    return response
        .whereType<Map<Object?, Object?>>()
        .map((row) {
          return Revalidation(
            id: row['id']?.toString() ?? '',
            status: row['status']?.toString() ?? 'unknown',
          );
        })
        .toList(growable: false);
  }

  @override
  Future<TrashOperation?> beginTrashOperation(TrashOperation operation) async {
    final result = await _invoke('beginTrashOperation', {
      'operationId': operation.id,
      'items': operation.items
          .map((item) => item.toJson())
          .toList(growable: false),
    });
    return _operation(result);
  }

  @override
  Future<TrashOperation?> readTrashOperation() async =>
      _operation(await _invoke('getTrashOperation'));

  @override
  Future<TrashOperation?> reconcileTrashOperation({
    String? operationId,
    bool afterSystemScreenClosed = false,
  }) async => _operation(
    await _invoke('reconcileTrashOperation', {
      'operationId': operationId ?? '',
      'afterSystemScreenClosed': afterSystemScreenClosed,
    }),
  );

  @override
  Future<TrashOperation?> continueTrashOperation(String operationId) async =>
      _operation(
        await _invoke('continueTrashOperation', {'operationId': operationId}),
      );

  @override
  Future<void> clearTrashOperation(String operationId) async {
    final result = await _invoke('clearTrashOperation', {
      'operationId': operationId,
    });
    if (result != true) {
      throw StateError(
        '$appDisplayName could not close the operation journal.',
      );
    }
  }

  TrashOperation? _operation(Object? value) {
    if (value == null) return null;
    return TrashOperation.fromJson(Map<String, Object?>.from(value as Map));
  }
}
