import 'dart:convert';

import 'hirang_theme_id.dart';

const int reviewStateVersion = 1;

/// Stable snapshot of a MediaStore item or a clearly isolated demo fixture.
class PhotoAsset {
  const PhotoAsset({
    required this.id,
    required this.title,
    this.uri,
    this.volumeName,
    this.mediaId,
    this.generationAdded,
    this.generationModified,
    this.volumeVersion,
    this.album,
    this.relativePath,
    this.dateTakenMillis,
    this.sizeBytes,
    this.screenshotHeuristic = false,
    this.demoIndex,
  });

  final String id;
  final String title;
  final String? uri;
  final String? volumeName;
  final int? mediaId;
  final int? generationAdded;
  final int? generationModified;
  final String? volumeVersion;
  final String? album;
  final String? relativePath;
  final int? dateTakenMillis;
  final int? sizeBytes;
  final bool screenshotHeuristic;
  final int? demoIndex;

  bool get isDemo => demoIndex != null;
  bool hasSameStableIdentity(PhotoAsset other) =>
      !isDemo &&
      !other.isDemo &&
      id == other.id &&
      uri != null &&
      uri!.isNotEmpty &&
      uri == other.uri &&
      volumeName != null &&
      volumeName!.isNotEmpty &&
      volumeName == other.volumeName &&
      mediaId != null &&
      mediaId == other.mediaId &&
      generationAdded != null &&
      generationAdded == other.generationAdded &&
      volumeVersion != null &&
      volumeVersion!.isNotEmpty &&
      volumeVersion == other.volumeVersion;
  DateTime? get captureDate => dateTakenMillis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(dateTakenMillis!);

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'uri': uri,
    'volumeName': volumeName,
    'mediaId': mediaId,
    'generationAdded': generationAdded,
    'generationModified': generationModified,
    'volumeVersion': volumeVersion,
    'album': album,
    'relativePath': relativePath,
    'dateTakenMillis': dateTakenMillis,
    'sizeBytes': sizeBytes,
    'screenshotHeuristic': screenshotHeuristic,
    'demoIndex': demoIndex,
  };

  factory PhotoAsset.fromJson(Map<String, Object?> json) => PhotoAsset(
    id: json['id'] as String,
    title: json['title'] as String? ?? 'Untitled photo',
    uri: json['uri'] as String?,
    volumeName: json['volumeName'] as String?,
    mediaId: (json['mediaId'] as num?)?.toInt(),
    generationAdded: (json['generationAdded'] as num?)?.toInt(),
    generationModified: (json['generationModified'] as num?)?.toInt(),
    volumeVersion: json['volumeVersion'] as String?,
    album: json['album'] as String?,
    relativePath: json['relativePath'] as String?,
    dateTakenMillis: (json['dateTakenMillis'] as num?)?.toInt(),
    sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
    screenshotHeuristic: json['screenshotHeuristic'] as bool? ?? false,
    demoIndex: (json['demoIndex'] as num?)?.toInt(),
  );
}

class ReviewFilters {
  const ReviewFilters({
    this.monthKey,
    this.album,
    this.screenshotsOnly = false,
  });

  final String? monthKey;
  final String? album;
  final bool screenshotsOnly;

  ReviewFilters copyWith({
    String? monthKey,
    bool clearMonth = false,
    String? album,
    bool clearAlbum = false,
    bool? screenshotsOnly,
  }) => ReviewFilters(
    monthKey: clearMonth ? null : monthKey ?? this.monthKey,
    album: clearAlbum ? null : album ?? this.album,
    screenshotsOnly: screenshotsOnly ?? this.screenshotsOnly,
  );

  Map<String, Object?> toJson() => {
    'monthKey': monthKey,
    'album': album,
    'screenshotsOnly': screenshotsOnly,
  };

  factory ReviewFilters.fromJson(Map<String, Object?> json) => ReviewFilters(
    monthKey: json['monthKey'] as String?,
    album: json['album'] as String?,
    screenshotsOnly: json['screenshotsOnly'] as bool? ?? false,
  );

  List<PhotoAsset> apply(Iterable<PhotoAsset> items) => items
      .where((item) {
        if (screenshotsOnly && !item.screenshotHeuristic) return false;
        if (album != null && item.album != album) return false;
        if (monthKey != null) {
          final date = item.captureDate;
          if (date == null ||
              '${date.year}-${date.month.toString().padLeft(2, '0')}' !=
                  monthKey) {
            return false;
          }
        }
        return true;
      })
      .toList(growable: false);
}

enum ReviewDecision { keep, mark }

enum OperationItemOutcome { pending, trashed, stillPresent, unknown, cancelled }

class TrashOperation {
  const TrashOperation({
    required this.id,
    required this.createdAtMillis,
    required this.items,
    required this.outcomes,
    required this.status,
    this.nextBatchStart = 0,
  });

  final String id;
  final int createdAtMillis;
  final List<PhotoAsset> items;
  final Map<String, OperationItemOutcome> outcomes;
  final String status;
  final int nextBatchStart;

  bool get isActive => const {
    'prepared',
    'awaitingSystemApproval',
    'resultReceived',
    'needsContinue',
    'reconciling',
  }.contains(status);

  bool locks(String itemId) =>
      isActive && items.any((item) => item.id == itemId);

  int get verifiedTrashedCount => outcomes.values
      .where((value) => value == OperationItemOutcome.trashed)
      .length;
  int get unresolvedCount => outcomes.values
      .where(
        (value) =>
            value == OperationItemOutcome.pending ||
            value == OperationItemOutcome.unknown ||
            value == OperationItemOutcome.stillPresent ||
            value == OperationItemOutcome.cancelled,
      )
      .length;

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAtMillis': createdAtMillis,
    'items': items.map((item) => item.toJson()).toList(),
    'outcomes': outcomes.map((key, value) => MapEntry(key, value.name)),
    'status': status,
    'nextBatchStart': nextBatchStart,
  };

  factory TrashOperation.fromJson(Map<String, Object?> json) {
    final rawOutcomes = json['outcomes'] as Map? ?? const {};
    return TrashOperation(
      id: json['id'] as String,
      createdAtMillis: (json['createdAtMillis'] as num?)?.toInt() ?? 0,
      items: (json['items'] as List? ?? const [])
          .map(
            (item) =>
                PhotoAsset.fromJson(Map<String, Object?>.from(item as Map)),
          )
          .toList(growable: false),
      outcomes: rawOutcomes.map(
        (key, value) => MapEntry(
          key.toString(),
          OperationItemOutcome.values.firstWhere(
            (outcome) => outcome.name == value,
            orElse: () => OperationItemOutcome.unknown,
          ),
        ),
      ),
      status: json['status'] as String? ?? 'unknown',
      nextBatchStart: (json['nextBatchStart'] as num?)?.toInt() ?? 0,
    );
  }

  TrashOperation copyWith({
    Map<String, OperationItemOutcome>? outcomes,
    String? status,
    int? nextBatchStart,
  }) => TrashOperation(
    id: id,
    createdAtMillis: createdAtMillis,
    items: items,
    outcomes: outcomes ?? this.outcomes,
    status: status ?? this.status,
    nextBatchStart: nextBatchStart ?? this.nextBatchStart,
  );
}

class ReviewState {
  const ReviewState({
    this.demoMode = false,
    this.onboardingComplete = false,
    this.themeId = HirangThemeId.amihan,
    this.filters = const ReviewFilters(),
    this.decisions = const {},
    this.knownAssets = const {},
    this.terminalTrashedIds = const {},
    this.appliedTrashOutcomes = const {},
    this.undoHistory = const [],
    this.operation,
  });

  final bool demoMode;
  final bool onboardingComplete;
  final HirangThemeId themeId;
  final ReviewFilters filters;
  final Map<String, ReviewDecision> decisions;
  final Map<String, PhotoAsset> knownAssets;
  final Set<String> terminalTrashedIds;

  /// Durable event keys prevent an old native result from undoing a later restore.
  final Map<String, Set<String>> appliedTrashOutcomes;
  final List<String> undoHistory;
  final TrashOperation? operation;

  /// The most recent undo entry in the active deck, unless frozen by a
  /// pending system trash request.
  String? get undoableId {
    final index = undoHistory.lastIndexWhere(
      (id) => knownAssets[id]?.isDemo == demoMode,
    );
    if (index < 0) return null;
    final id = undoHistory[index];
    return operation?.locks(id) == true ? null : id;
  }

  bool get canUndo => undoableId != null;

  factory ReviewState.initial() => const ReviewState();

  factory ReviewState.decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return ReviewState.initial();
    try {
      final json = Map<String, Object?>.from(jsonDecode(encoded) as Map);
      if (json['version'] != reviewStateVersion) return ReviewState.initial();
      final rawDecisions = json['decisions'] as Map? ?? const {};
      final rawAssets = json['knownAssets'] as Map? ?? const {};
      final rawAppliedTrashOutcomes =
          json['appliedTrashOutcomes'] as Map? ?? const {};
      final rawOperation = json['operation'];
      return ReviewState(
        demoMode: json['demoMode'] as bool? ?? false,
        // Additive migration: older version-1 snapshots keep every decision and
        // journal, while new users see the first-run introduction.
        onboardingComplete: json['onboardingComplete'] as bool? ?? false,
        themeId: HirangThemeId.fromStorage(json['themeId']),
        filters: ReviewFilters.fromJson(
          Map<String, Object?>.from(json['filters'] as Map? ?? const {}),
        ),
        decisions: rawDecisions.map(
          (key, value) => MapEntry(
            key.toString(),
            ReviewDecision.values.firstWhere(
              (decision) => decision.name == value,
              orElse: () => ReviewDecision.keep,
            ),
          ),
        ),
        knownAssets: rawAssets.map(
          (key, value) => MapEntry(
            key.toString(),
            PhotoAsset.fromJson(Map<String, Object?>.from(value as Map)),
          ),
        ),
        terminalTrashedIds: (json['terminalTrashedIds'] as List? ?? const [])
            .whereType<String>()
            .toSet(),
        appliedTrashOutcomes: rawAppliedTrashOutcomes.map(
          (key, value) => MapEntry(
            key.toString(),
            (value as List? ?? const []).whereType<String>().toSet(),
          ),
        ),
        undoHistory: (json['undoHistory'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        operation: rawOperation is Map
            ? TrashOperation.fromJson(Map<String, Object?>.from(rawOperation))
            : null,
      );
    } on Object {
      return ReviewState.initial();
    }
  }

  String encode() => jsonEncode({
    'version': reviewStateVersion,
    'demoMode': demoMode,
    'onboardingComplete': onboardingComplete,
    'themeId': themeId.storageId,
    'filters': filters.toJson(),
    'decisions': decisions.map((key, value) => MapEntry(key, value.name)),
    'knownAssets': knownAssets.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'terminalTrashedIds': terminalTrashedIds.toList(),
    'appliedTrashOutcomes': {
      for (final entry in appliedTrashOutcomes.entries)
        entry.key: entry.value.toList()..sort(),
    },
    'undoHistory': undoHistory,
    'operation': operation?.toJson(),
  });

  ReviewState copyWith({
    bool? demoMode,
    bool? onboardingComplete,
    HirangThemeId? themeId,
    ReviewFilters? filters,
    Map<String, ReviewDecision>? decisions,
    Map<String, PhotoAsset>? knownAssets,
    Set<String>? terminalTrashedIds,
    Map<String, Set<String>>? appliedTrashOutcomes,
    List<String>? undoHistory,
    TrashOperation? operation,
    bool clearOperation = false,
  }) => ReviewState(
    demoMode: demoMode ?? this.demoMode,
    onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    themeId: themeId ?? this.themeId,
    filters: filters ?? this.filters,
    decisions: decisions ?? this.decisions,
    knownAssets: knownAssets ?? this.knownAssets,
    terminalTrashedIds: terminalTrashedIds ?? this.terminalTrashedIds,
    appliedTrashOutcomes: appliedTrashOutcomes ?? this.appliedTrashOutcomes,
    undoHistory: undoHistory ?? this.undoHistory,
    operation: clearOperation ? null : operation ?? this.operation,
  );

  ReviewState withDemoMode(bool value) => copyWith(demoMode: value);
  ReviewState withFilters(ReviewFilters value) => copyWith(filters: value);

  /// Reopens only an exact, previously confirmed identity returned by the
  /// current accessible non-trashed MediaStore query. Absence is never evidence.
  ReviewState reconcileRestoredAssets(
    Iterable<PhotoAsset> accessibleAssets, {
    Map<String, Set<String>>? appliedEventsAtSnapshot,
  }) {
    if (demoMode || terminalTrashedIds.isEmpty || operation?.isActive == true) {
      return this;
    }
    final snapshotEvents = appliedEventsAtSnapshot ?? appliedTrashOutcomes;
    final nextTerminalIds = Set<String>.from(terminalTrashedIds);
    final nextKnownAssets = Map<String, PhotoAsset>.from(knownAssets);
    for (final current in accessibleAssets) {
      if (current.isDemo || !nextTerminalIds.contains(current.id)) continue;
      final journalContainsItem =
          operation?.items.any((item) => item.id == current.id) ?? false;
      if (journalContainsItem &&
          operation?.outcomes[current.id] != OperationItemOutcome.trashed) {
        continue;
      }
      final previous = knownAssets[current.id];
      if (previous == null || !previous.hasSameStableIdentity(current)) {
        continue;
      }
      // A query started before a newly applied success cannot prove restoration.
      final newSuccessAppliedAfterQuery = appliedTrashOutcomes.entries.any(
        (entry) =>
            entry.value.contains(current.id) &&
            !(snapshotEvents[entry.key]?.contains(current.id) ?? false),
      );
      if (newSuccessAppliedAfterQuery) continue;
      nextTerminalIds.remove(current.id);
      nextKnownAssets[current.id] = current;
    }
    if (nextTerminalIds.length == terminalTrashedIds.length) return this;
    // Existing keep/mark decisions and undo history are intentionally retained.
    return copyWith(
      terminalTrashedIds: nextTerminalIds,
      knownAssets: nextKnownAssets,
    );
  }

  ReviewState decide(PhotoAsset item, ReviewDecision decision) {
    if (item.isDemo != demoMode) {
      throw StateError('This photo belongs to a different deck.');
    }
    if (terminalTrashedIds.contains(item.id)) {
      throw StateError(
        'This exact photo identity was already confirmed in system trash.',
      );
    }
    if (operation?.locks(item.id) ?? false) {
      throw StateError('This photo is frozen while a trash request is active.');
    }
    if (decisions.containsKey(item.id)) {
      throw StateError('This photo already has a review decision.');
    }
    return copyWith(
      decisions: {...decisions, item.id: decision},
      knownAssets: {...knownAssets, item.id: item},
      undoHistory: [...undoHistory, item.id],
    );
  }

  ReviewState undo() {
    final index = undoHistory.lastIndexWhere(
      (id) => knownAssets[id]?.isDemo == demoMode,
    );
    if (index < 0) return this;
    final id = undoHistory[index];
    if (operation?.locks(id) ?? false) {
      throw StateError(
        'Undo is unavailable while this photo is frozen for a system request.',
      );
    }
    final nextDecisions = Map<String, ReviewDecision>.from(decisions)
      ..remove(id);
    final nextHistory = List<String>.from(undoHistory)..removeAt(index);
    return copyWith(decisions: nextDecisions, undoHistory: nextHistory);
  }

  ReviewState unmark(String id) {
    if (operation?.locks(id) ?? false) {
      throw StateError('This photo is frozen while a trash request is active.');
    }
    if (decisions[id] != ReviewDecision.mark) return this;
    final nextDecisions = Map<String, ReviewDecision>.from(decisions)
      ..remove(id);
    return copyWith(
      decisions: nextDecisions,
      undoHistory: undoHistory
          .where((entry) => entry != id)
          .toList(growable: false),
    );
  }

  List<PhotoAsset> filteredAssets(Iterable<PhotoAsset> assets) => filters
      .apply(assets.where((item) => item.isDemo == demoMode))
      .where((item) => !terminalTrashedIds.contains(item.id))
      .toList(growable: false);

  PhotoAsset? nextUnreviewed(Iterable<PhotoAsset> assets) {
    for (final item in filteredAssets(assets)) {
      if (!decisions.containsKey(item.id) &&
          !(operation?.locks(item.id) ?? false)) {
        return item;
      }
    }
    return null;
  }

  int reviewedCount(Iterable<PhotoAsset> assets) =>
      filteredAssets(assets)
          .where((item) => decisions.containsKey(item.id))
          .length;

  List<PhotoAsset> markedAssets() => knownAssets.values
      .where((item) => item.isDemo == demoMode)
      .where((item) => decisions[item.id] == ReviewDecision.mark)
      .where((item) => !terminalTrashedIds.contains(item.id))
      .toList(growable: false);

  ReviewState beginTrashOperation({
    required String operationId,
    required int nowMillis,
    required List<PhotoAsset> items,
  }) {
    if (operation?.isActive ?? false) {
      throw StateError('A trash operation is already active.');
    }
    final unique = <String>{};
    for (final item in items) {
      if (!unique.add(item.id)) {
        throw StateError('The selected list contains duplicate photos.');
      }
      if (decisions[item.id] != ReviewDecision.mark) {
        throw StateError(
          'Only currently marked photos can be submitted for trash.',
        );
      }
    }
    if (items.isEmpty) throw StateError('Select at least one marked photo.');
    return copyWith(
      operation: TrashOperation(
        id: operationId,
        createdAtMillis: nowMillis,
        items: List.unmodifiable(items),
        outcomes: {
          for (final item in items) item.id: OperationItemOutcome.pending,
        },
        status: 'prepared',
      ),
    );
  }

  ReviewState updateOperation(TrashOperation value) {
    final applied = {
      for (final entry in appliedTrashOutcomes.entries)
        entry.key: Set<String>.from(entry.value),
    };
    final newlyConfirmed = <String>{};
    for (final entry in value.outcomes.entries) {
      if (entry.value != OperationItemOutcome.trashed) continue;
      if (applied.putIfAbsent(value.id, () => <String>{}).add(entry.key)) {
        newlyConfirmed.add(entry.key);
      }
    }
    if (newlyConfirmed.isEmpty) {
      return copyWith(operation: value, appliedTrashOutcomes: applied);
    }
    final nextDecisions = Map<String, ReviewDecision>.from(decisions)
      ..removeWhere((id, _) => newlyConfirmed.contains(id));
    return copyWith(
      operation: value,
      appliedTrashOutcomes: applied,
      decisions: nextDecisions,
      terminalTrashedIds: {...terminalTrashedIds, ...newlyConfirmed},
      undoHistory: undoHistory
          .where((id) => !newlyConfirmed.contains(id))
          .toList(growable: false),
    );
  }

  ReviewState clearFinishedOperation() {
    if (operation?.isActive ?? false) {
      throw StateError('An active trash operation cannot be cleared.');
    }
    return copyWith(clearOperation: true);
  }
}
