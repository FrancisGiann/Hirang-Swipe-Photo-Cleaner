import 'dart:async';

import 'package:hirang/domain/review_state.dart';
import 'package:hirang/platform/sift_gateway.dart';

import 'fake_sift_gateway.dart';

typedef FakePhotoPageLoader = FutureOr<PhotoPage> Function(
  FakePhotoPageRequest request,
);

class FakePagedSiftGateway extends FakeSiftGateway
    implements PagedPhotoGateway {
  FakePhotoPageLoader? pageLoader;
  final List<FakePhotoPageRequest> pageRequests = [];

  @override
  Future<PhotoPage> queryPhotoPage({
    required PhotoQueryMode mode,
    required int pageSize,
    String? cursor,
    ReviewFilters filters = const ReviewFilters(),
  }) async {
    final request = FakePhotoPageRequest(
      mode: mode,
      pageSize: pageSize,
      cursor: cursor,
      filters: filters,
    );
    pageRequests.add(request);
    return await pageLoader?.call(request) ??
        const PhotoPage(items: [], status: 'unsupported');
  }
}

class FakePhotoPageRequest {
  const FakePhotoPageRequest({
    required this.mode,
    required this.pageSize,
    required this.cursor,
    required this.filters,
  });

  final PhotoQueryMode mode;
  final int pageSize;
  final String? cursor;
  final ReviewFilters filters;
}
