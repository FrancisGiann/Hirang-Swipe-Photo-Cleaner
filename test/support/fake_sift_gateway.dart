import 'dart:async';
import 'dart:typed_data';

import 'package:hirang/domain/review_state.dart';
import 'package:hirang/platform/sift_gateway.dart';

class FakeSiftGateway implements SiftGateway {
  ReviewState saved = ReviewState.initial();
  PhotoAccess access = const PhotoAccess(status: 'denied', sdkInt: 36);
  List<PhotoAsset> photos = const [];
  Uint8List? thumbnailData;
  int thumbnailWidth = 1600;
  int thumbnailHeight = 2200;
  bool sourceDetailAvailable = true;
  Future<PhotoImageData?> Function(PhotoAsset, int, bool)? photoImageLoader;
  Object? thumbnailException;
  Completer<PhotoImageData?>? thumbnailCompleter;
  final Map<String, Completer<PhotoImageData?>> imageCompletersById = {};
  final Map<String, Completer<PhotoImageData?>> imageCompletersByRequest = {};
  final List<FakePhotoImageRequest> imageRequests = [];
  int activeImageRequests = 0;
  int maxActiveImageRequests = 0;
  TrashOperation? operation;
  Map<String, String> validationStatuses = const {};
  int beginCalls = 0;
  int loadCalls = 0;
  int saveCalls = 0;
  int permissionRequests = 0;
  Object? loadException;
  Object? saveException;
  Object? readException;
  int reconcileCalls = 0;
  bool lastReconcileAcknowledged = false;
  bool appSettingsOpened = false;
  Completer<TrashOperation?>? beginCompleter;
  Completer<TrashOperation?>? readCompleter;
  Completer<List<Revalidation>>? revalidationCompleter;
  Completer<void>? saveCompleter;
  List<String> revalidatedIds = const [];
  Object? queryException;
  Completer<ReviewState>? loadCompleter;

  @override
  Future<ReviewState> loadState() async {
    loadCalls++;
    if (loadException case final exception?) throw exception;
    if (loadCompleter case final pending?) return pending.future;
    return saved;
  }

  @override
  Future<void> saveState(ReviewState state) async {
    saveCalls++;
    if (saveException case final exception?) throw exception;
    if (saveCompleter case final pending?) await pending.future;
    saved = ReviewState.decode(state.encode());
  }

  @override
  Future<PhotoAccess> permissionStatus() async => access;

  @override
  Future<PhotoAccess> requestPhotoAccess() async {
    permissionRequests++;
    return access;
  }

  @override
  Future<void> openAppSettings() async {
    appSettingsOpened = true;
  }

  @override
  Future<List<PhotoAsset>> queryPhotos() async {
    if (queryException case final exception?) throw exception;
    return photos;
  }

  @override
  Future<PhotoImageData?> loadPhotoImage(
    PhotoAsset item, {
    required int maxEdge,
    bool preferSourceDetail = false,
  }) async {
    final request = FakePhotoImageRequest(
      id: item.id,
      maxEdge: maxEdge,
      preferSourceDetail: preferSourceDetail,
    );
    imageRequests.add(request);
    activeImageRequests++;
    if (activeImageRequests > maxActiveImageRequests) {
      maxActiveImageRequests = activeImageRequests;
    }
    try {
      if (thumbnailException case final exception?) throw exception;
      if (imageCompletersByRequest[request.key] case final pending?) {
        return await pending.future;
      }
      if (imageCompletersById[item.id] case final pending?) {
        return await pending.future;
      }
      if (thumbnailCompleter case final pending?) return await pending.future;
      if (photoImageLoader case final loader?) {
        return await loader(item, maxEdge, preferSourceDetail);
      }
      final bytes = thumbnailData;
      if (bytes == null) return null;
      return PhotoImageData(
        bytes: bytes,
        width: thumbnailWidth,
        height: thumbnailHeight,
        isSourceDetail: preferSourceDetail && sourceDetailAvailable,
      );
    } finally {
      activeImageRequests--;
    }
  }

  @override
  Future<List<Revalidation>> revalidate(List<PhotoAsset> items) {
    revalidatedIds = items.map((item) => item.id).toList(growable: false);
    final results = items
        .map(
          (item) => Revalidation(
            id: item.id,
            status: validationStatuses[item.id] ?? 'present',
          ),
        )
        .toList(growable: false);
    return revalidationCompleter?.future ?? Future.value(results);
  }

  @override
  Future<TrashOperation?> beginTrashOperation(TrashOperation operation) {
    beginCalls++;
    if (beginCompleter != null) return beginCompleter!.future;
    this.operation = operation.copyWith(status: 'awaitingSystemApproval');
    return Future.value(this.operation);
  }

  @override
  Future<TrashOperation?> readTrashOperation() {
    if (readException case final exception?) throw exception;
    return readCompleter?.future ?? Future.value(operation);
  }

  @override
  Future<TrashOperation?> reconcileTrashOperation({
    String? operationId,
    bool afterSystemScreenClosed = false,
  }) async {
    reconcileCalls++;
    lastReconcileAcknowledged = afterSystemScreenClosed;
    final current = operation;
    if (current == null || current.id != operationId) return current;
    if (current.status == 'awaitingSystemApproval' &&
        !afterSystemScreenClosed) {
      return current;
    }
    if (current.status == 'awaitingSystemApproval' && afterSystemScreenClosed) {
      operation = current.copyWith(
        status: 'interrupted',
        outcomes: {
          for (final item in current.items)
            item.id: OperationItemOutcome.unknown,
        },
      );
    } else if (current.status == 'resultReceived') {
      operation = current.copyWith(status: 'complete');
    } else if (current.status == 'prepared') {
      operation = current.copyWith(status: 'interrupted');
    }
    return operation;
  }

  @override
  Future<TrashOperation?> continueTrashOperation(String operationId) async {
    final current = operation;
    if (current == null || current.id != operationId) return null;
    operation = current.copyWith(status: 'awaitingSystemApproval');
    return operation;
  }

  @override
  Future<void> clearTrashOperation(String operationId) async {
    if (operation?.id != operationId || operation?.isActive == true) {
      throw StateError('stale clear');
    }
    operation = null;
  }
}

PhotoAsset realPhoto(String id, {int mediaId = 1, int generationAdded = 1}) =>
    PhotoAsset(
      id: id,
      title: 'Fixture $id',
      uri: 'content://media/external_primary/images/media/$mediaId',
      volumeName: 'external_primary',
      volumeVersion: 'fixture-catalog-v1',
      mediaId: mediaId,
      generationAdded: generationAdded,
      generationModified: 1,
      album: 'Fixture album',
      relativePath: 'Pictures/Fixture/',
      dateTakenMillis: 1_700_000_000_000,
      sizeBytes: 1024,
    );

class FakePhotoImageRequest {
  const FakePhotoImageRequest({
    required this.id,
    required this.maxEdge,
    required this.preferSourceDetail,
  });

  final String id;
  final int maxEdge;
  final bool preferSourceDetail;

  String get key => '$id|$maxEdge|$preferSourceDetail';
}
