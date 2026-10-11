import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../domain/review_state.dart';
import '../platform/sift_gateway.dart';

class _PhotoImageCache {
  static final LinkedHashMap<String, _PhotoImageCacheEntry> _entries =
      LinkedHashMap();
  static const int maxEntries = 12;
  static const int maxCompressedBytes = 16 * 1024 * 1024;
  static const int maxConcurrentLoads = 2;
  static const int maxPendingForegroundLoads = 24;
  static const int maxPendingGridLoads = 24;
  static int _retainedBytes = 0;
  static int _activeLoads = 0;
  static final Map<String, _PhotoImageJob> _inFlight = {};
  static final Map<String, _PhotoImageJob> _queuedByKey = {};
  static final Map<String, int> _visibleKeyCounts = {};
  static final Queue<_PhotoImageJob> _pendingForeground = Queue();
  static final Queue<_PhotoImageJob> _pendingGrid = Queue();
  static final List<_PhotoLookahead> _lookahead = [];
  static final Map<String, String> _desiredLookahead = {};
  static _PhotoImageJob? _activeSpeculative;
  static bool _preferGridNext = false;
  static final Expando<MemoryImage> _providers = Expando(
    'photo image provider',
  );
  static final Expando<bool> _warming = Expando('photo image warming');

  static String _identity(PhotoAsset item) =>
      '${item.id}|${item.uri}|${item.volumeName}|${item.mediaId}|'
      '${item.volumeVersion}|${item.generationAdded}|${item.generationModified}';

  static String requestKey(
    SiftGateway gateway,
    PhotoAsset item, {
    required int maxEdge,
    required bool sourceDetail,
  }) =>
      '${identityHashCode(gateway)}|${_identity(item)}|edge=$maxEdge|source=$sourceDetail';

  static Future<PhotoImageData?> load(
    SiftGateway gateway,
    PhotoAsset item, {
    required int maxEdge,
    required bool sourceDetail,
    required _PhotoRequestKind kind,
    bool cardForeground = false,
    bool deferDispatch = false,
  }) {
    final edge = maxEdge.clamp(96, 2048).toInt();
    final key = requestKey(
      gateway,
      item,
      maxEdge: edge,
      sourceDetail: sourceDetail,
    );
    final cached = _entries.remove(key);
    if (cached != null) {
      if (kind != _PhotoRequestKind.speculative) cached.speculative = false;
      _entries[key] = cached;
      if (!deferDispatch) scheduleMicrotask(_dispatchPending);
      return Future<PhotoImageData?>.value(cached.image);
    }
    final active = _inFlight[key];
    if (active != null && !active.invalidated) {
      _promote(active, kind, cardForeground);
      if (!deferDispatch) _dispatchPending();
      return active.completer.future;
    }
    final queued = _queuedByKey[key];
    if (queued != null) {
      _promote(queued, kind, cardForeground);
      if (!deferDispatch) _dispatchPending();
      return queued.completer.future;
    }

    _lookahead.removeWhere((request) => request.key == key);
    if (kind == _PhotoRequestKind.grid &&
        _pendingGrid.length >= maxPendingGridLoads) {
      return Future<PhotoImageData?>.value();
    }
    if (kind == _PhotoRequestKind.foreground &&
        _pendingForeground.length >= maxPendingForegroundLoads) {
      final dropped = _pendingForeground.removeFirst();
      _queuedByKey.remove(dropped.key);
      _finishQueueTiming(dropped);
      if (!dropped.completer.isCompleted) dropped.completer.complete(null);
    }
    final request = _PhotoImageJob(
      key: key,
      identity: _identity(item),
      gateway: gateway,
      item: item,
      maxEdge: edge,
      sourceDetail: sourceDetail,
      kind: kind,
      cardForeground: cardForeground,
    );
    _queue(request);
    if (!deferDispatch) _dispatchPending();
    return request.completer.future;
  }

  static void _queue(_PhotoImageJob request) {
    _queuedByKey[request.key] = request;
    if (request.kind == _PhotoRequestKind.grid) {
      _pendingGrid.addLast(request);
    } else {
      _pendingForeground.addLast(request);
    }
  }

  static void _promote(
    _PhotoImageJob job,
    _PhotoRequestKind kind,
    bool cardForeground,
  ) {
    if (kind == _PhotoRequestKind.speculative) return;
    if (job.kind == _PhotoRequestKind.speculative) {
      if (identical(_activeSpeculative, job)) _activeSpeculative = null;
      job.obsoleteSpeculative = false;
      job.kind = kind;
    } else if (kind == _PhotoRequestKind.foreground &&
        job.kind == _PhotoRequestKind.grid) {
      if (identical(_queuedByKey[job.key], job) && _pendingGrid.remove(job)) {
        _pendingForeground.addLast(job);
      }
      job.kind = kind;
    }
    job.cardForeground |= cardForeground;
  }

  static void _start(_PhotoImageJob job) {
    if (job.invalidated || _inFlight.containsKey(job.key)) return;
    _queuedByKey.remove(job.key);
    _finishQueueTiming(job);
    _activeLoads++;
    _inFlight[job.key] = job;
    if (job.kind == _PhotoRequestKind.speculative) _activeSpeculative = job;
    late final Future<PhotoImageData?> future;
    try {
      future = job.gateway.loadPhotoImage(
        job.item,
        maxEdge: job.maxEdge,
        preferSourceDetail: job.sourceDetail,
      );
    } catch (error, stack) {
      future = Future<PhotoImageData?>.error(error, stack);
    }
    unawaited(
      future.then<void>(
        (image) => _finishLoad(job, image: image),
        onError: (Object error, StackTrace stack) =>
            _finishLoad(job, error: error, stack: stack),
      ),
    );
  }

  static void _finishLoad(
    _PhotoImageJob job, {
    PhotoImageData? image,
    Object? error,
    StackTrace? stack,
  }) {
    _activeLoads = (_activeLoads - 1).clamp(0, maxConcurrentLoads).toInt();
    if (identical(_inFlight[job.key], job)) _inFlight.remove(job.key);
    if (identical(_activeSpeculative, job)) _activeSpeculative = null;
    try {
      if (job.invalidated || job.obsoleteSpeculative) {
        if (!job.completer.isCompleted) job.completer.complete(null);
      } else if (error != null) {
        if (!job.completer.isCompleted) {
          job.completer.completeError(error, stack);
        }
      } else {
        if (image != null) _remember(job, image);
        if (!job.completer.isCompleted) job.completer.complete(image);
      }
    } finally {
      _dispatchPending();
    }
  }

  static void _dispatchPending() {
    while (_activeLoads < maxConcurrentLoads) {
      final request = _takeNextVisible();
      if (request != null) {
        if (!request.completer.isCompleted) _start(request);
        continue;
      }
      if (_pendingForeground.isNotEmpty || _pendingGrid.isNotEmpty) return;
      if (_activeSpeculative != null) return;
      final lookahead = _takeNextLookahead();
      if (lookahead == null) return;
      final specJob = _PhotoImageJob(
        key: lookahead.key,
        identity: _identity(lookahead.item),
        gateway: lookahead.gateway,
        item: lookahead.item,
        maxEdge: lookahead.maxEdge,
        sourceDetail: lookahead.sourceDetail,
        kind: _PhotoRequestKind.speculative,
      );
      specJob.completer.future.catchError((Object _) => null);
      _start(specJob);
    }
  }

  static _PhotoImageJob? _takeNextVisible() {
    final foreground = _takeRunnable(_pendingForeground);
    final grid = _takeRunnable(_pendingGrid);
    if (foreground != null && grid != null) {
      if (_preferGridNext) {
        _pendingForeground.addFirst(foreground);
        _preferGridNext = false;
        return grid;
      }
      _pendingGrid.addFirst(grid);
      _preferGridNext = true;
      return foreground;
    }
    return foreground ?? grid;
  }

  static _PhotoImageJob? _takeRunnable(Queue<_PhotoImageJob> queue) {
    final blocked = <_PhotoImageJob>[];
    _PhotoImageJob? result;
    while (queue.isNotEmpty) {
      final request = queue.removeFirst();
      if (request.invalidated || request.completer.isCompleted) {
        if (identical(_queuedByKey[request.key], request)) {
          _queuedByKey.remove(request.key);
        }
        continue;
      }
      if (!_inFlight.containsKey(request.key)) {
        result = request;
        if (identical(_queuedByKey[request.key], request)) {
          _queuedByKey.remove(request.key);
        }
        break;
      }
      blocked.add(request);
    }
    queue.addAll(blocked);
    return result;
  }

  static _PhotoLookahead? _takeNextLookahead() {
    for (var index = 0; index < _lookahead.length; index++) {
      final request = _lookahead[index];
      if (_entries.containsKey(request.key) ||
          _queuedByKey.containsKey(request.key)) {
        _lookahead.removeAt(index--);
        continue;
      }
      if (_inFlight.containsKey(request.key)) continue;
      return _lookahead.removeAt(index);
    }
    return null;
  }

  static void prefetch(
    SiftGateway gateway, {
    required PhotoAsset current,
    required int detailMaxEdge,
    required Iterable<PhotoAsset> upcoming,
  }) {
    final normalizedDetailEdge = detailMaxEdge.clamp(96, 2048).toInt();
    setVisibleCard(gateway, current, normalizedDetailEdge);
    final assets = upcoming.take(3).toList(growable: false);
    final next = <_PhotoLookahead>[];
    if (assets.isNotEmpty) {
      next.add(
        _PhotoLookahead(
          gateway: gateway,
          item: assets.first,
          maxEdge: normalizedDetailEdge,
          sourceDetail: true,
        ),
      );
    }
    for (final item in assets.take(2)) {
      next.add(
        _PhotoLookahead(
          gateway: gateway,
          item: item,
          maxEdge: 512,
          sourceDetail: false,
        ),
      );
    }
    final keys = next.map((request) => request.key).toSet();
    final keepKeys = <String>{
      ...keys,
      requestKey(gateway, current, maxEdge: 512, sourceDetail: false),
      requestKey(
        gateway,
        current,
        maxEdge: normalizedDetailEdge,
        sourceDetail: true,
      ),
    };
    _lookahead
      ..clear()
      ..addAll(next);
    _desiredLookahead
      ..clear()
      ..addEntries(
        next.map((request) => MapEntry(request.key, _identity(request.item))),
      );
    for (final entry in _entries.entries.toList()) {
      if (entry.value.speculative && !keepKeys.contains(entry.key)) {
        _remove(entry.key);
      }
    }
    final activeSpeculative = _activeSpeculative;
    if (activeSpeculative != null) {
      activeSpeculative.obsoleteSpeculative = !keepKeys.contains(
        activeSpeculative.key,
      );
    }
    scheduleMicrotask(_dispatchPending);
  }

  static void setVisibleCard(
    SiftGateway gateway,
    PhotoAsset item,
    int detailMaxEdge,
  ) {
    final identity = _identity(item);
    for (final job in _pendingForeground.toList(growable: false)) {
      if (!job.cardForeground) continue;
      final belongs =
          identical(job.gateway, gateway) &&
          job.identity == identity &&
          (job.sourceDetail
              ? job.maxEdge == detailMaxEdge
              : job.maxEdge == 512);
      if (!belongs) _cancelQueued(job);
    }
  }

  static void _cancelQueued(_PhotoImageJob job) {
    _pendingForeground.remove(job);
    _pendingGrid.remove(job);
    if (identical(_queuedByKey[job.key], job)) _queuedByKey.remove(job.key);
    _finishQueueTiming(job);
    if (!job.completer.isCompleted) job.completer.complete(null);
  }

  static void _finishQueueTiming(_PhotoImageJob job) {
    job.finishQueueTiming();
  }

  static void retainVisibleKey(String key) {
    _visibleKeyCounts.update(key, (count) => count + 1, ifAbsent: () => 1);
    final entry = _entries[key];
    if (entry != null) {
      entry.visibleReferences++;
      entry.speculative = false;
    }
  }

  static void releaseVisibleKey(String key) {
    final count = _visibleKeyCounts[key] ?? 0;
    if (count <= 1) {
      _visibleKeyCounts.remove(key);
    } else {
      _visibleKeyCounts[key] = count - 1;
    }
    final entry = _entries[key];
    if (entry != null && entry.visibleReferences > 0) {
      entry.visibleReferences--;
    }
  }

  static void cancelPrefetch() {
    _lookahead.clear();
    _desiredLookahead.clear();
    final activeSpeculative = _activeSpeculative;
    if (activeSpeculative != null) activeSpeculative.obsoleteSpeculative = true;
  }

  static void invalidate(PhotoAsset item) {
    final identity = _identity(item);
    for (final key in _entries.keys.toList()) {
      if (_entries[key]?.identity == identity) _remove(key);
    }
    for (final job in _inFlight.values) {
      if (job.identity == identity) job.invalidated = true;
    }
    for (final job in _queuedByKey.values.toList()) {
      if (job.identity == identity) _cancelQueued(job);
    }
    _lookahead.removeWhere((request) => _identity(request.item) == identity);
    _desiredLookahead.removeWhere(
      (_, itemIdentity) => itemIdentity == identity,
    );
    if (_activeSpeculative?.identity == identity) {
      _activeSpeculative!.invalidated = true;
    }
    _dispatchPending();
  }

  static void invalidateAll() {
    for (final key in _entries.keys.toList()) {
      _remove(key);
    }
    for (final job in _inFlight.values) {
      job.invalidated = true;
    }
    for (final job in _queuedByKey.values.toList()) {
      _cancelQueued(job);
    }
    _lookahead.clear();
    _desiredLookahead.clear();
    if (_activeSpeculative != null) _activeSpeculative!.invalidated = true;
    _dispatchPending();
  }

  static MemoryImage providerFor(PhotoImageData image) =>
      _providers[image.bytes] ??= MemoryImage(image.bytes);

  static void _warm(MemoryImage provider) {
    if (_warming[provider] == true) return;
    _warming[provider] = true;
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          stream.removeListener(listener);
          image.dispose();
          _warming[provider] = null;
        });
      },
      onError: (_, _) {
        stream.removeListener(listener);
        _warming[provider] = null;
      },
    );
    stream.addListener(listener);
  }

  static void _remember(_PhotoImageJob job, PhotoImageData image) {
    final byteLength = image.bytes.length;
    if (byteLength == 0 || byteLength > maxCompressedBytes) return;
    while (_entries.length >= maxEntries ||
        _retainedBytes + byteLength > maxCompressedBytes) {
      String? candidate;
      for (final entry in _entries.entries) {
        if (entry.value.visibleReferences == 0 &&
            entry.value.speculative &&
            !_desiredLookahead.containsKey(entry.key)) {
          candidate = entry.key;
          break;
        }
      }
      if (candidate == null) {
        for (final entry in _entries.entries) {
          if (entry.value.visibleReferences == 0 && !entry.value.speculative) {
            candidate = entry.key;
            break;
          }
        }
      }
      if (candidate == null && job.kind != _PhotoRequestKind.speculative) {
        for (final entry in _entries.entries) {
          if (entry.value.visibleReferences == 0) {
            candidate = entry.key;
            break;
          }
        }
      }
      if (candidate == null) return;
      _remove(candidate);
    }
    final provider = providerFor(image);
    _entries[job.key] = _PhotoImageCacheEntry(
      image: image,
      identity: job.identity,
      completedBytes: byteLength,
      provider: provider,
      speculative: job.kind == _PhotoRequestKind.speculative,
      visibleReferences: _visibleKeyCounts[job.key] ?? 0,
    );
    _retainedBytes += byteLength;
    if (job.kind == _PhotoRequestKind.speculative) {
      unawaited(_warmSpeculativeWhenBudget(job.key, image, provider));
    } else {
      _warm(provider);
    }
  }

  static Future<void> _warmSpeculativeWhenBudget(
    String key,
    PhotoImageData image,
    MemoryImage provider,
  ) async {
    final cache = PaintingBinding.instance.imageCache;
    final estimatedBytes = image.width * image.height * 4;
    if (estimatedBytes <= 0 || estimatedBytes > cache.maximumSizeBytes) return;

    bool fits() =>
        cache.currentSizeBytes + estimatedBytes <= cache.maximumSizeBytes;
    if (!fits()) {
      for (final entry in _entries.entries.toList(growable: false)) {
        if (fits()) break;
        if (!entry.value.speculative ||
            entry.value.visibleReferences != 0 ||
            _desiredLookahead.containsKey(entry.key)) {
          continue;
        }
        final staleProvider = entry.value.provider;
        _remove(entry.key);
        if (!_entries.values.any(
          (retained) => identical(retained.provider, staleProvider),
        )) {
          await staleProvider.evict();
        }
      }
    }
    final entry = _entries[key];
    if (entry?.speculative == true && entry?.visibleReferences == 0 && fits()) {
      _warm(provider);
    }
  }

  static void _remove(String key) {
    final removed = _entries.remove(key);
    if (removed == null) return;
    _retainedBytes -= removed.completedBytes;
    final sharesBytes = _entries.values.any(
      (entry) => identical(entry.image.bytes, removed.image.bytes),
    );
    if (!sharesBytes) {
      _providers[removed.image.bytes] = null;
      unawaited(removed.provider.evict());
    }
  }
}

enum _PhotoRequestKind { foreground, grid, speculative }

class _PhotoLookahead {
  _PhotoLookahead({
    required this.gateway,
    required this.item,
    required this.maxEdge,
    required this.sourceDetail,
  }) : key = _PhotoImageCache.requestKey(
         gateway,
         item,
         maxEdge: maxEdge,
         sourceDetail: sourceDetail,
       );

  final String key;
  final SiftGateway gateway;
  final PhotoAsset item;
  final int maxEdge;
  final bool sourceDetail;
}

class _PhotoImageJob {
  _PhotoImageJob({
    required this.key,
    required this.identity,
    required this.gateway,
    required this.item,
    required this.maxEdge,
    required this.sourceDetail,
    required this.kind,
    this.cardForeground = false,
  }) : queueClock = Stopwatch()..start(),
       queueTiming = _startQueueTiming();

  static developer.TimelineTask? _startQueueTiming() {
    if (!kDebugMode && !kProfileMode) return null;
    return developer.TimelineTask()..start('Hirang photo queue wait');
  }

  final String key;
  final String identity;
  final SiftGateway gateway;
  final PhotoAsset item;
  final int maxEdge;
  final bool sourceDetail;
  final Stopwatch queueClock;
  final Completer<PhotoImageData?> completer = Completer();
  final developer.TimelineTask? queueTiming;
  _PhotoRequestKind kind;
  bool cardForeground;
  bool invalidated = false;
  bool obsoleteSpeculative = false;
  bool _queueTimingFinished = false;

  void finishQueueTiming() {
    if (_queueTimingFinished) return;
    _queueTimingFinished = true;
    queueTiming?.finish(
      arguments: {'queue_ms': queueClock.elapsedMilliseconds},
    );
  }
}

class _PhotoImageCacheEntry {
  _PhotoImageCacheEntry({
    required this.image,
    required this.identity,
    required this.completedBytes,
    required this.provider,
    required this.speculative,
    required this.visibleReferences,
  });

  final PhotoImageData image;
  final String identity;
  final int completedBytes;
  final MemoryImage provider;
  bool speculative;
  int visibleReferences;
}

class PhotoArtwork extends StatefulWidget {
  const PhotoArtwork({
    super.key,
    required this.item,
    required this.demoMode,
    required this.gateway,
    this.fit = BoxFit.cover,
    this.maxEdge = 512,
    this.preferSourceDetail = false,
  });

  final PhotoAsset item;
  final bool demoMode;
  final SiftGateway gateway;
  final BoxFit fit;
  final int maxEdge;
  final bool preferSourceDetail;

  static final ValueNotifier<int> _cacheRevision = ValueNotifier(0);

  static void prefetch(
    SiftGateway gateway, {
    required PhotoAsset current,
    required int detailMaxEdge,
    required Iterable<PhotoAsset> upcoming,
  }) => _PhotoImageCache.prefetch(
    gateway,
    current: current,
    detailMaxEdge: detailMaxEdge,
    upcoming: upcoming,
  );

  static void cancelPrefetch() => _PhotoImageCache.cancelPrefetch();

  static void invalidate(PhotoAsset item) {
    _PhotoImageCache.invalidate(item);
    _cacheRevision.value++;
  }

  static void invalidateAll() {
    _PhotoImageCache.invalidateAll();
    _cacheRevision.value++;
  }

  @override
  State<PhotoArtwork> createState() => _PhotoArtworkState();
}

class _PhotoArtworkState extends State<PhotoArtwork> {
  late String _inputKey;
  int _loadGeneration = 0;
  PhotoImageData? _preview;
  PhotoImageData? _detail;
  bool _previewFailed = false;
  bool _previewDecodeFailed = false;
  bool _detailFailed = false;
  bool _detailDecodeFailed = false;
  bool _detailDecodeFailureQueued = false;
  bool _detailFrameReady = false;
  bool _detailFrameReadyQueued = false;
  final Set<String> _visibleImageKeys = {};
  developer.TimelineTask? _detailFrameTiming;

  String _keyFor(PhotoArtwork value) =>
      '${_PhotoImageCache.requestKey(value.gateway, value.item, maxEdge: value.maxEdge, sourceDetail: value.preferSourceDetail)}|demo=${value.demoMode}';

  @override
  void initState() {
    super.initState();
    PhotoArtwork._cacheRevision.addListener(_onCacheInvalidated);
    _load();
  }

  @override
  void didUpdateWidget(covariant PhotoArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKey = _keyFor(widget);
    if (nextKey != _inputKey) _load();
  }

  @override
  void dispose() {
    PhotoArtwork._cacheRevision.removeListener(_onCacheInvalidated);
    _releaseVisibleImages();
    _finishDetailTiming();
    super.dispose();
  }

  void _onCacheInvalidated() {
    if (!mounted) return;
    setState(_load);
  }

  void _load() {
    _releaseVisibleImages();
    _inputKey = _keyFor(widget);
    final generation = ++_loadGeneration;
    _preview = null;
    _detail = null;
    _previewFailed = false;
    _previewDecodeFailed = false;
    _detailFailed = false;
    _detailDecodeFailed = false;
    _detailDecodeFailureQueued = false;
    _detailFrameReady = false;
    _detailFrameReadyQueued = false;
    _finishDetailTiming();
    if (widget.demoMode) return;

    if (widget.preferSourceDetail) {
      _retainVisibleImageKey(widget.maxEdge, sourceDetail: true);
      _retainVisibleImageKey(512, sourceDetail: false);
      _detailFrameTiming = _startDetailTiming();
      _observe(
        _PhotoImageCache.load(
          widget.gateway,
          widget.item,
          maxEdge: 512,
          sourceDetail: false,
          kind: _PhotoRequestKind.foreground,
          cardForeground: true,
          deferDispatch: true,
        ),
        generation: generation,
        detail: false,
      );
      _observe(
        _PhotoImageCache.load(
          widget.gateway,
          widget.item,
          maxEdge: widget.maxEdge,
          sourceDetail: true,
          kind: _PhotoRequestKind.foreground,
          cardForeground: true,
        ),
        generation: generation,
        detail: true,
      );
    } else {
      _retainVisibleImageKey(widget.maxEdge, sourceDetail: false);
      _observe(
        _PhotoImageCache.load(
          widget.gateway,
          widget.item,
          maxEdge: widget.maxEdge,
          sourceDetail: false,
          kind: _PhotoRequestKind.grid,
        ),
        generation: generation,
        detail: false,
      );
    }
  }

  void _retainVisibleImageKey(int edge, {required bool sourceDetail}) {
    final key = _PhotoImageCache.requestKey(
      widget.gateway,
      widget.item,
      maxEdge: edge,
      sourceDetail: sourceDetail,
    );
    if (_visibleImageKeys.add(key)) {
      _PhotoImageCache.retainVisibleKey(key);
    }
  }

  void _releaseVisibleImages() {
    for (final key in _visibleImageKeys) {
      _PhotoImageCache.releaseVisibleKey(key);
    }
    _visibleImageKeys.clear();
  }

  void _observe(
    Future<PhotoImageData?> future, {
    required int generation,
    required bool detail,
  }) {
    future.then<void>(
      (image) {
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          if (detail) {
            _detail = image;
            _detailFailed = image == null;
          } else {
            _preview = image;
            _previewFailed = image == null;
          }
        });
        if (detail && image == null) _finishDetailTiming();
      },
      onError: (Object _, StackTrace _) {
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          if (detail) {
            _detailFailed = true;
          } else {
            _previewFailed = true;
          }
        });
        if (detail) _finishDetailTiming();
      },
    );
  }

  developer.TimelineTask? _startDetailTiming() {
    if (!kDebugMode && !kProfileMode) return null;
    return developer.TimelineTask()..start('Hirang photo Flutter frame ready');
  }

  void _finishDetailTiming() {
    _detailFrameTiming?.finish();
    _detailFrameTiming = null;
  }

  void _detailImageFailed(int generation) {
    if (_detailDecodeFailureQueued || generation != _loadGeneration) return;
    _detailDecodeFailureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _detailDecodeFailed = true);
      _finishDetailTiming();
    });
  }

  void _detailFrameArrived(int generation) {
    if (_detailFrameReady ||
        _detailFrameReadyQueued ||
        generation != _loadGeneration) {
      return;
    }
    _detailFrameReadyQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _detailFrameReady = true);
      _finishDetailTiming();
    });
  }

  void _previewImageFailed(int generation) {
    if (generation != _loadGeneration) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _loadGeneration || _previewDecodeFailed) {
        return;
      }
      setState(() => _previewDecodeFailed = true);
    });
  }

  void _retry() => PhotoArtwork.invalidate(widget.item);

  Widget _loadingPlaceholder() => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: const Center(
      child: CircularProgressIndicator(semanticsLabel: 'Loading photo preview'),
    ),
  );

  Widget _smallLoadingIndicator() => Align(
    alignment: Alignment.bottomRight,
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: IgnorePointer(
        child: Semantics(
          label: 'Loading higher-detail photo',
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface
                  .withValues(alpha: .94),
              shape: BoxShape.circle,
            ),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _detailRetryNotice() => Positioned(
    left: 10,
    bottom: 10,
    child: Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: .95),
      borderRadius: BorderRadius.circular(18),
      elevation: 2,
      child: TextButton.icon(
        onPressed: _retry,
        icon: const Icon(Icons.refresh_rounded, size: 17),
        label: const Text('Retry detail'),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: const Size(40, 40),
        ),
      ),
    ),
  );

  Widget _photoImage(
    PhotoImageData image, {
    required String key,
    required bool detail,
    required int generation,
  }) => Image(
    key: ValueKey(key),
    image: _PhotoImageCache.providerFor(image),
    fit: widget.fit,
    filterQuality: FilterQuality.high,
    gaplessPlayback: false,
    semanticLabel: widget.item.title,
    frameBuilder: (context, child, frame, synchronousCall) {
      if (frame != null) {
        if (detail) _detailFrameArrived(generation);
        return child;
      }
      return detail && _preview != null && !_previewDecodeFailed
          ? _smallLoadingIndicator()
          : _loadingPlaceholder();
    },
    errorBuilder: (context, error, stack) {
      if (detail) {
        _detailImageFailed(generation);
        return const SizedBox.shrink();
      }
      if (widget.preferSourceDetail) {
        _previewImageFailed(generation);
        return const SizedBox.shrink();
      }
      return PhotoPlaceholder(
        title: widget.item.title,
        icon: Icons.broken_image_outlined,
        message: 'Photo preview unavailable',
        onRetry: _retry,
      );
    },
  );

  Widget _buildPhoto() {
    if (!widget.preferSourceDetail) {
      final image = _preview;
      if (image == null) {
        return _previewFailed
            ? PhotoPlaceholder(
                title: widget.item.title,
                icon: Icons.photo_outlined,
                message: 'Photo preview unavailable',
                onRetry: _retry,
              )
            : _loadingPlaceholder();
      }
      return _photoImage(
        image,
        key: 'image-$_inputKey',
        detail: false,
        generation: _loadGeneration,
      );
    }

    final detail = _detail;
    final preview = _preview;
    if (detail != null && !_detailDecodeFailed) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (!_detailFrameReady)
            if (preview != null && !_previewDecodeFailed)
              _photoImage(
                preview,
                key: 'preview-$_inputKey',
                detail: false,
                generation: _loadGeneration,
              )
            else
              _loadingPlaceholder(),
          _photoImage(
            detail,
            key: 'detail-$_inputKey',
            detail: true,
            generation: _loadGeneration,
          ),
          if (!detail.isSourceDetail)
            Positioned(
              right: 10,
              bottom: 10,
              child: _PreviewQualityNotice(onRetry: _retry),
            ),
        ],
      );
    }
    if (preview != null && !_previewDecodeFailed) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _photoImage(
            preview,
            key: 'preview-$_inputKey',
            detail: false,
            generation: _loadGeneration,
          ),
          if (_detailDecodeFailed)
            Positioned(
              right: 10,
              bottom: 10,
              child: _PreviewQualityNotice(onRetry: _retry),
            )
          else if (_detailFailed)
            _detailRetryNotice()
          else
            _smallLoadingIndicator(),
        ],
      );
    }
    if (_previewFailed && _detailFailed) {
      return PhotoPlaceholder(
        title: widget.item.title,
        icon: Icons.broken_image_outlined,
        message: 'Photo preview unavailable',
        onRetry: _retry,
      );
    }
    return _loadingPlaceholder();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.demoMode) {
      return DemoArtwork(
        index: widget.item.demoIndex ?? 0,
        title: widget.item.title,
      );
    }
    return _buildPhoto();
  }
}

class _PreviewQualityNotice extends StatelessWidget {
  const _PreviewQualityNotice({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'A smaller preview is shown because a higher-detail image is unavailable.',
      child: Tooltip(
        message: 'Higher-detail photo unavailable; showing a preview.',
        child: Material(
          color: colors.surface.withValues(alpha: .94),
          borderRadius: BorderRadius.circular(12),
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.photo_size_select_small_rounded,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Preview only',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (onRetry != null) ...[
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Retry higher-detail photo',
                    onPressed: onRetry,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DemoArtwork extends StatelessWidget {
  const DemoArtwork({super.key, required this.index, required this.title});

  final int index;
  final String title;

  static const _colors = [
    [Color(0xFFEAAB73), Color(0xFF7B5944)],
    [Color(0xFFDA7C73), Color(0xFF73624A)],
    [Color(0xFF84B3B2), Color(0xFF233F4C)],
    [Color(0xFFD7BD83), Color(0xFF58684F)],
    [Color(0xFF687CA5), Color(0xFF252F4D)],
    [Color(0xFF90A979), Color(0xFF35483D)],
    [Color(0xFFC69C78), Color(0xFF52453B)],
    [Color(0xFF6E8A9D), Color(0xFF343D4D)],
  ];
  static const _symbols = [
    Icons.wb_sunny_rounded,
    Icons.local_florist_rounded,
    Icons.waves_rounded,
    Icons.coffee_rounded,
    Icons.nights_stay_rounded,
    Icons.park_rounded,
    Icons.auto_awesome_rounded,
    Icons.photo_camera_back_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _colors[index % _colors.length];
    return CustomPaint(
      painter: _DemoArtworkPainter(colors),
      child: Center(
        child: FractionallySizedBox(
          widthFactor: .34,
          child: AspectRatio(
            aspectRatio: 1,
            child: Icon(
              _symbols[index % _symbols.length],
              color: const Color(0xFFFFF9ED).withValues(alpha: .92),
              size: 128,
            ),
          ),
        ),
      ),
    );
  }
}

class _DemoArtworkPainter extends CustomPainter {
  const _DemoArtworkPainter(this.colors);

  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final background = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(rect);
    canvas.drawRect(rect, background);

    final side = size.width;
    final firstCircle = Paint()
      ..color = Colors.white.withValues(alpha: .11)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final firstCenter = Offset(side * .75, side * .47);
    canvas.drawCircle(firstCenter, side * .39, firstCircle);
    final firstOutline = Paint()
      ..color = Colors.white.withValues(alpha: .23)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..isAntiAlias = true;
    canvas.drawCircle(firstCenter, side * .39, firstOutline);

    final secondCircle = Paint()
      ..color = colors.last.withValues(alpha: .45)
      ..isAntiAlias = true;
    canvas.drawCircle(
      Offset(side * .39, size.height - side * .43),
      side * .28,
      secondCircle,
    );
  }

  @override
  bool shouldRepaint(_DemoArtworkPainter oldDelegate) =>
      oldDelegate.colors != colors;
}

class PhotoPlaceholder extends StatelessWidget {
  const PhotoPlaceholder({
    super.key,
    required this.title,
    required this.icon,
    this.message,
    this.onRetry,
  });

  final String title;
  final IconData icon;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 210 || constraints.maxWidth < 220;
      final textTheme = Theme.of(context).textTheme;
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: compact ? 24 : 38),
                SizedBox(height: compact ? 4 : 8),
                Text(
                  title,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: compact ? textTheme.labelSmall : null,
                ),
                if (message != null) ...[
                  SizedBox(height: compact ? 2 : 4),
                  Text(
                    compact ? 'Preview unavailable' : message!,
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall,
                  ),
                ],
                if (onRetry != null) ...[
                  SizedBox(height: compact ? 2 : 4),
                  if (compact)
                    IconButton(
                      tooltip: 'Retry photo preview',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                    )
                  else
                    TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
