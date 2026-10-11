# Hirang — Android photo review app plan

Updated: 10 October 2026. The Android MVP and requested coherent redesign, first-launch introduction, generated practice flow, original launcher icon and live swipe-intent feedback are implemented. The photo clarity fix and three saved appearance themes are also implemented. Version 1.0.4 (5) is packaged as a signed local ARM64 release-mode APK. Final analysis, 60 Flutter tests, 19 native JVM tests, real screen rendering, and package inspection pass. Device-specific photo access, system-trash/recovery behavior, TalkBack, and frame pacing remain engineering verification; no hardware behavior is presented as measured.

## 1. Goal and scope

Help someone clean their accessible local photo library in short sessions without deleting anything accidentally. Left marks a photo for the final batch; right keeps it. Undo reverses review decisions. Every destructive operation requires marked-item review, explicit app confirmation, and the applicable Android system approval.

The implemented app covers photos only, month/album/screenshots filters, resumable review progress, and an honest estimate of selected local file sizes. The app has no account, backend, telemetry, or internet permission. It disables backup and excludes SharedPreferences from cloud backup and device transfer; the APK manifest was inspected, but runtime backup behavior has not been tested. Videos, duplicates, AI, editing, monetization, iOS, and a full in-app trash browser are deferred.

**Design clarification resolved:** this is an Android-native app with Apple-level motion polish, not an iOS UI copy. No specific reference app is required to proceed.

## 2. Stack and boundaries

- Flutter/Dart implements the UI, gesture decisions, filters, demo fixtures, and local review state. The app uses Flutter's gesture and spring primitives, explicit action buttons, and a reduced-animation path.
- Kotlin accesses Android `MediaStore`/`ContentResolver` for permission state, per-volume photo metadata and bounded previews, identity checks, and `MediaStore.createTrashRequest`.
- A Kotlin platform channel is used instead of a third-party photo package because trash, selected-photo access, and per-item reconciliation require narrow semantics. There is no permanent-delete request or fallback path.
- Flutter review state and the native operation journal use local SharedPreferences. Dart writes are serialized; the native journal uses a revision guard and operation reservation around the system-prompt lifecycle. The app stores no photo copies on disk. Restart, provider, and permission behavior still need device validation.

## 3. Implemented screens and flow

| Screen | Current behavior |
| --- | --- |
| First-launch introduction | Four skippable pages explain Keep/Mark/Undo, marked review, local privacy, and recovery/storage limits before any permission request. Generated hands-on practice touches no personal photos. Completion is saved; back/interruption, save failure, and later replay are handled without resetting review decisions. |
| Sample / photo access | The final introduction offers Choose photos, Try the sample deck, or Not now. A generated fictional eight-item deck works without permission. Full, selected, and denied access remain distinct; requests are explicit. |
| Photo review | Compact header and progress, a photo viewer that uses available height, one-line metadata outside the photo, photo details with View photo larger, balanced Mark/Keep buttons, smaller Undo, and a marked count. Short/large-text layouts can scroll; Undo works after the last card. |
| Filters | A scrollable sheet replaces the clipped horizontal controls. Month, album and screenshot filters intersect; Reset/Done are explicit and saved unavailable filters remain visible. |
| Settings / appearance | Photo options → Settings → Appearance → Theme. Amihan is the default; Dapithapon is warm/light and Hatinggabi is dark. Visual radio cards preview the palettes. Selection saves locally, applies immediately and preserves the current route, review decisions and filters. Failed saves retain the previous selection with a retry message. |
| Photo options / supporting states | Access management, refresh, Android app settings, help and introduction replay. Limited access is actionable. Empty libraries, query failures, saved-state recovery and operation results have consistent styling and distinct next actions. |
| Marked-item review | Thumbnail grid with unmarking, counts and known/unknown estimated sizes. Preflight captures one immutable selection and freezes unmarking; a concurrent selection change requires fresh confirmation. Active operations retain item locks. |
| Confirmation / result | Full in-app confirmation precedes Android approval. The button now says Review system confirmation (formerly Continue to Android); it launches the system request, not a success result, and explains that photos move only after system approval. Verified trash, partial results, cancellation and unresolved/inaccessible items stay distinct. System dialogs and provider outcomes remain hardware validation items. |

**Happy path:** introduction → explicit sample or photo-access choice → filter → swipe/button/undo → marked review → app confirmation → Android trash approval → reconcile.

**Safe exit:** review state persists locally. Startup remains gated until saved state and the native operation journal are read and reconciled. Failed reads or required writes show retry without overwriting saved decisions or starting another operation. Present malformed native journal data is an error, not an absent operation; valid legacy records remain readable. Callback error paths release their reservation and preserve unreadable journal bytes. A pending system prompt keeps its journal locked until the user explicitly confirms returning after closing it. There is no background cleanup or automatic retry. Unresolved items require fresh confirmation. If a lifecycle refresh overlaps a closed-screen recheck, a further visible recheck may be needed; items stay locked meanwhile.

**Filters:** month, album, and screenshot heuristic filters intersect. Screenshots use an OEM-dependent folder/bucket-name heuristic. Dates use DATE_TAKEN, falling back to DATE_ADDED when capture time is missing; month grouping uses the device local timezone. Imported photos may appear under their import month. Missing date/album/size remain unknown. Provider metadata and screenshot recognition still need device validation.

## 4. Android API notes and implementation policy

Android's current official API references were checked on 10 October 2026 against target SDK 36. Permission and trash request code is implemented but has not yet been exercised on an emulator or phone.

| Device API | Reading other apps' photos | Implementation |
| --- | --- | --- |
| 30–32 (Android 11–12L) | Runtime `READ_EXTERNAL_STORAGE`. | Minimum API 30; manifest permission is capped at API 32. |
| 33 (Android 13) | Runtime `READ_MEDIA_IMAGES`. | Image permission only; no video/audio permission. |
| 34+ (Android 14+) | Full access or selected-photo access; `READ_MEDIA_VISUAL_USER_SELECTED` is requested with image access. | Access is checked from the system on demand; permission requests are user-triggered and the library refreshes on resume. |
| 29 and below | Different legacy/scoped-storage mutation paths. | Unsupported; minimum SDK is 30. |

The Android 13 [granular media permission guidance](https://developer.android.com/about/versions/13/behavior-changes-13#granular-media-permissions) and Android 14 [partial-access guidance](https://developer.android.com/about/versions/14/changes/partial-photo-video-access) govern this matrix. Limited access is not a full-library scan. Do not persist a permission boolean as authority: access can change, and compatibility-mode grants can expire. Requery the accessible subset after permission changes; hidden items are not proof of deletion.

The app queries local `MediaStore.Images` items rather than importing through the Photo Picker; it does not request `MANAGE_EXTERNAL_STORAGE`, `MANAGE_MEDIA`, location, or internet access. Android's [Photo Picker](https://developer.android.com/training/data-storage/shared/photo-picker) may expose cloud media and is not used for cleaning. The built APK was inspected and contains only the intended read-media permissions plus AndroidX's internal receiver permission. Any later Play release must separately verify eligibility for broad photo access; approval is not assumed.

### Marked queue and system trash

These are separate states:

| Action | Meaning and behavior |
| --- | --- |
| Swipe left / mark | Record a local decision only. The original stays untouched; Undo or unmark reverses the decision. |
| Move to system trash | `MediaStore.createTrashRequest(..., true)` requests recoverable trash after app review and Android approval. The app verifies the specific item state afterward where it remains accessible; missing/inaccessible rows stay unknown. |
| Permanent deletion | Excluded from this MVP. There is no permanent-delete request or fallback. |

The Android trash API prompts for system approval, requires specific MediaStore item URIs, and completes the requested operation before the Activity result. The result is not a per-item report. Target-36+ requests are capped at 2,000 URIs; this implementation chunks conservatively at 250. See the official [MediaStore API reference](https://developer.android.com/reference/android/provider/MediaStore#createTrashRequest(android.content.ContentResolver,%20java.util.Collection%3Candroid.net.Uri%3E)).

**Recovery and storage:** system trash is the only destructive MVP path. Whether a device shows the expected prompt, its media provider accepts the request, or a trashed item can be restored from a gallery's trash view remains a device/provider validation item. Android [trash metadata](https://developer.android.com/reference/android/provider/MediaStore.MediaColumns#IS_TRASHED) is time-limited and default queries hide trashed items; the app promises no retention duration, recovery route, or immediate freed-space result. In-app Undo only reverses review decisions before a trash request.

**Restoration reconciliation:** after synchronizing the native operation journal, a fresh query can reopen a previously verified-trash identity when that exact photo is accessible and nontrashed again. The stable match includes its URI, volume, item ID, volume version, and insertion generation; a changed modified generation alone does not make it a replacement. Only the current trash marker is cleared, preserving Keep/Mark decisions and undo history. A durable operation-and-item outcome ledger prevents repeated old journal loads from erasing later decisions or marking the restored item as trashed again. A separately confirmed new operation can trash that identity again; historical result counts still describe the past operation.

**Restoration limits:** a missing row, denied or limited-access omission, failed query, or unknown matching operation is not proof of restoration or deletion. Active operations retain their locks. Limited access can establish restoration only for an exact identity positively returned in the accessible subset. If a provider restores with a new URI, insertion generation, or catalog version, it appears as a new review identity; the app cannot infer continuity or transfer old decisions. Missing original identity metadata remains unresolved. There is no in-app restore API or history reset. Host tests cover these rules; actual gallery/provider restoration still needs disposable-photo device validation.

### Batch safety and honest results

1. Capture one immutable marked selection and revalidate its URIs, access, identity, and current state before confirmation. Show changed/unavailable items and update its count/estimate. Compare the exact selection again inside the serialized submission; reject changes and require fresh confirmation before writing a new journal or opening Android approval. Avoid stale numeric IDs or paths identifying a replacement photo.
2. Freeze and journal the confirmed URI list, operation kind, and batch status locally before launching the system request. Prevent double taps from starting a second operation.
3. On cancellation, keep unresolved marks and report cancellation. If prior chunks succeeded, preserve those successes and stop the remaining chunks.
4. After each result, requery under current permissions; explicitly include trashed items when checking trash. Distinguish verified trashed, still present, no longer accessible, and unknown. Absence caused by revoked access is not deletion success.
5. After a crash, missing callback, stale URI, or partial failure, reconcile before any retry. No all-or-nothing guarantee across batches. Never repeat already verified successes.

Refresh MediaStore and permission state on resume; queries and thumbnail reads run off the drag path. Decisions use a volume/item identity plus generation metadata so a reused item ID does not inherit old marks. The native adapter validates exact per-volume item URIs before requests, journals the frozen batch, and treats missing/inaccessible rows as unknown rather than verified success. Android's [shared media guide](https://developer.android.com/training/data-storage/shared/media) covers worker-thread queries, thumbnails, and cache/version reconciliation. These paths have helper tests but need disposable-photo device/provider tests.

**Cloud-backed photos:** MVP operates only on supported local MediaStore items. Skip cloud-only/provider-only content; do not download it to make cleaning possible. The app cannot promise that a local deletion removes a cloud backup or that another gallery's sync will leave it intact. Validate provider-specific behavior with disposable test assets later, and explain uncertainty before acting. No integration with cloud libraries is planned.

**Space estimate:** sum known local file sizes and show unknown-size items separately. Label the amount **Estimated selected size**; system trash can continue to use storage, so this is not a promise of space reclaimed. Cloud size and later free-space readings are not inferred.

## 5. Motion, native behavior, and accessibility

- Cards follow the finger directly with restrained translation/rotation and a clear Mark/Keep indication. Green KEEP/check and red MARK FOR REMOVAL/bookmark feedback uses the same horizontal distance threshold as release readiness. Holding or reversing the drag changes only feedback. Release below that threshold or cancellation springs back without changing the decision; velocity tunes the spring rather than bypassing the distance gate.
- Use velocity-aware springs for settle and dismissal. Regrab a settling card from its current position/velocity; Undo returns coherently. Transitions must be smoothly interruptible and reversible, with one decision per completed action and no queued animation blocking input.
- Subtle haptics at meaningful decision boundaries, respecting device/user capability. Avoid repeated vibrations during drag. Tune physics and haptics on hardware, not by copying fixed iPhone constants.
- Restrained system-compatible typography, generous consistent spacing, readable contrast, and coherent light/dark themes. Respect Android edge-to-edge insets, back/predictive-back behavior where supported, navigation gestures, and native permission/system dialogs. These dialogs keep Android's appearance.
- Explicit Mark/Keep/Undo buttons, TalkBack labels and state announcements, large touch targets, text scaling, and indications beyond color alone.
- Honor Android Remove animations through Flutter's reduced/disabled-animation signals. Replace rotations and long spring travel with short fades or immediate state changes; preserve the same interaction/results. Flutter documents [animation accessibility behavior](https://api.flutter.dev/flutter/animation/AnimationBehavior.html).
- Keep photo loading out of gesture-critical work: query/decode asynchronously, use sized thumbnails, bounded caching, and prefetch a few next cards. No unbounded full-resolution decode, synchronous I/O, or library-wide rebuild on drag. Missing thumbnails get stable placeholders and a recoverable error state.

### Appearance persistence and accessibility

Stable IDs `amihan`, `dapithapon` and `hatinggabi` are an additive field in the existing version-1 review state. Missing or unknown values use Amihan without discarding review decisions. Theme saves use the same serialized state-write queue as review actions; no new dependency, account or backend was added. The app-level theme listener preserves the navigator and home state. Palette changes have zero animation duration, including with reduced motion enabled.

Shared Material roles style welcome, tutorial, deck, marked review, dialogs, Settings and supporting states. Keep and Mark use separate green/red semantic roles with accessible foregrounds, independent of brand colors. Photos have no theme color filter. In the three rendered sample decks, the same 168,300-pixel photo interior was byte-identical. Representative actual text pairs are checked against 4.5:1 and control/icon pairs against 3:1, following [WCAG text contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) and [non-text contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html) as engineering targets. Large-text tests check narrow layouts; this is not a claim of full accessibility conformance.

### Photo preview sizing and loading

The 1.0.3 clarity fix replaces the fixed 768-pixel/JPEG-82 path for the active card and expanded view. Bounded `LayoutBuilder` dimensions multiplied by the actual device-pixel ratio choose a 64-pixel request bucket. Native `ImageDecoder` reads the exact source URI on a dedicated worker, uses orientation-normalized header dimensions, preserves aspect ratio, caps scale at the source size, and applies both a 2048-pixel edge and 3-million-pixel ceiling. Provider thumbnails remain the cheap grid/prefetch path and an explicitly labeled fallback if source detail cannot be decoded.

Current bounds: native image executor has two workers and four queued tasks; Dart starts at most three image loads, retains one newest pending detail request and up to 24 FIFO grid requests, and alternates them when both queues have work. It retains at most 12 encoded cache entries/16 MiB; Flutter's normal decoded cache is capped at 48 MiB (live images and decoder overhead are additional). Each channel payload is at most 12 MiB. Encoding tries lossless WebP then WebP quality 95. Bitmaps are recycled. Cache keys include gateway, complete stable identity, modification generation, request bucket and source/preview tier. Refresh invalidates mounted views and evicts their decoded providers. Grid overflow and unreadable media offer Retry, without an unbounded backlog.

Access and exact current identity/generation are rechecked before decoding, after decoding and after encoding. Changed requests reset the rendered image while waiting, preventing a previous photo from appearing under new metadata. Cold source loads use a loading placeholder; small next-item prefetch is a thumbnail optimization, not a guarantee of instant source detail. The app stores preview buffers in memory only and does not modify the original.

Primary platform sources: [Android ImageDecoder](https://developer.android.com/reference/android/graphics/ImageDecoder), [provider thumbnail contract](https://developer.android.com/reference/android/content/ContentResolver#loadThumbnail(android.net.Uri,android.util.Size,android.os.CancellationSignal)), [Flutter pixel density](https://api.flutter.dev/flutter/dart-ui/FlutterView/devicePixelRatio.html), and [Flutter image decoding](https://api.flutter.dev/flutter/widgets/Image-class.html). AOSP [orientation CTS](https://android.googlesource.com/platform/cts/+/refs/heads/main/tests/tests/graphics/src/android/graphics/cts/ImageDecoderTest.java#2090) covers all eight EXIF orientations; [current decoder source](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/libs/hwui/hwui/ImageDecoder.cpp#220) also normalizes header dimensions. These source checks are not a local Android runtime test.

Six focused Flutter checks cover identity/size/gateway separation, stale completion, same-identity invalidation, saturated foreground work, ten delayed grid tiles, and honest fallback/retry. Native tests cover aspect/pixel/byte bounds, no upscaling and current-generation identity. Actual DPR-3 renders use synthetic derivatives following the bounded sizing policy. They validate Flutter rendering and request sizing; native codecs, rotated media and limited-provider behavior still need disposable-fixture hardware tests. No personal library was scanned or modified.

## 6. Implementation status and engineering checks

The review flow, trash-only native adapter, startup recovery safeguards, first-launch introduction and requested visual redesign are implemented. Final flutter analyze is clean; all **60 Flutter tests** and **19 native JVM tests** pass. The native tests passed for the clarity milestone; native code is unchanged in the theme phase. Kotlin compiles and the signed ARM64 release-mode APK builds at build/app/outputs/flutter-apk/hirang-1.0.4-themes.apk. The same existing local Android development key signs version **1.0.4 (5)**; no store credentials were created. Package inspection confirms com.francisgiann.hirang, label Hirang, min SDK 30, target SDK 36, intended photo permissions, no INTERNET permission and no debuggable flag. allowBackup=false, fullBackupContent=false and extraction exclusions were inspected in the package, not exercised on hardware; see [Android Auto Backup](https://developer.android.com/identity/data/autobackup).

The APK is **17,851,348 bytes**; SHA-256 is `eadecc13dbb9bb1658305aa32076e96998c0aa7c386f91d2354c6d68f7e8a926`. No app was installed or launched on a phone, no personal photo library was scanned or modified, and no settings were changed during these checks.

Focused gesture regression checks cover hold, reversal, short/fast release, cancellation, matching release decisions, reduced motion and narrow large text. Theme tests cover migration, persistence/restart, failed saves, concurrent review/theme writes, live switching and reduced motion. Each palette has actual welcome, practice, deck, marked review, help, Settings, query-error and in-app system-trash confirmation renders. Actual app widgets generated **58 numbered screen captures** plus launcher previews, inspected as pixels. Coverage includes 393 × 886 logical pixels, a 360 × 812 deck at text scale 1.5, welcome/practice at large text, welcome/deck in dark mode, and supporting states at normal text/light. A focused 320-pixel-wide/text-scale-2 overflow check also passes. [VISUAL_REVIEW.md](VISUAL_REVIEW.md) indexes the evidence and limits; these are host Flutter renders, not Android system-dialog or hardware measurements.

| Phase | Implemented result | Later engineering verification |
| --- | --- | --- |
| 0 — Permissions and trash feasibility | Native APIs, full/limited/denied states, per-volume identity checks and conservative outcomes, before polished UI. | API 30–32, 33 and 34+ prompts, selected access and provider recovery with disposable photos. |
| 1 — Review core | Mark/Keep, final-card Undo, filters, progress persistence, marked review and recovery/access states. | Actual metadata, restart and provider behavior on hardware. |
| 2 — Trash safely | Two confirmations, exact-selection guard, frozen/chunked journal, revision/reservation guards, startup recovery, identity reconciliation and restoration replay protection. Native tests pass. | OS cancellation, restoration, revocation and process death with disposable assets. |
| 3 — Coherent UI and first use | Compact photo review, live swipe-intent feedback, scrollable filters, shared themes, generated practice, durable Skip/completion/replay and original adaptive/round/monochrome launcher icon. Real rendered screens inspected. | TalkBack, device insets/gestures, launcher masks and broader text/theme combinations. |
| 4 — Local installation | Version 1.0.4 (5) signed ARM64 APK; package, permissions, signature, size and hash inspected. Install/update steps in README. | Store signing, publication, eligibility and physical-device performance remain outside this local build. |

The remaining matrix is engineering-owned follow-up, not a prerequisite asking the user to perform basic QA.

## 7. Later physical-device engineering checks

These are engineering-owned follow-ups when a device or emulator is available, not a request for the user to run test cases. Use fixtures and disposable photos only. Seed test photos through a separate producer so they are not owned by the cleaner; own-media privileges must not mask real permission and confirmation behavior.

| Area | Test and expected result |
| --- | --- |
| First use | Fresh install shows the introduction before any permission prompt. Skip/Not now/back do not request access. Practice uses generated art; completion survives restart and replay preserves decisions. Exercise denied/limited access after the explicit choice. |
| Core safety | Left/right/button actions only change the local decision. No photo changes before both app and OS confirmation. Undo restores the previous decision, card, and counts. |
| Resume / filters | Kill and reopen after decisions; retain marks/keeps and resume position. Switching month/album/screenshots does not duplicate marks. Newly added photos enter unreviewed. Empty filters are clear. |
| Permissions | On API 30–32, 33, and 34+ test full/denied/revoked; on 34+ test limited/reselection. Only accessible photos/counts appear. Loss of access never becomes a successful delete. Add a current target-SDK device/emulator to the matrix. |
| Trash / restoration | Verify actual trash state and a supported gallery recovery route with disposable assets. An accessible restored exact identity becomes reviewable once; a subsequent Keep or Mark survives restart and old-journal replay. Changed identities do not inherit decisions; missing/limited-access omissions stay unresolved. Permanent deletion is not implemented or used as a fallback. |
| Cancel / batches | Cancel app confirmation and Android approval; unresolved marks remain. Cancel a later chunk after an earlier success; results distinguish both. Test an oversized list with bounded chunks and no duplicate requests. |
| Failure / lifecycle | Remove/replace a photo externally, revoke access during review, include an invalid URI, double tap confirm, kill the app around the prompt. Preserve the operation journal, reconcile outcomes, and require deliberate retry. |
| Estimates / cloud | Known and unknown sizes, duplicate URIs, cloud-only assets, and already trashed items produce honest counts/estimates. No cloud download or guaranteed reclaimed-space claim. |
| Motion / access | Slow drags, fast flicks, direction reversals, regrabbing springs, rapid Undo, and back gestures give one correct decision. TalkBack, large text, light/dark, and Remove animations keep all controls usable. |
| Performance | Confirm access to Francis's **POCO M7 Pro 5G** later; record OS/build, actual active refresh mode, dataset, and thermal state. Use profile/release builds on hardware with large disposable libraries, cold/warm thumbnails, and repeated 30-second swipe/undo runs. Record Flutter UI/raster frame timings, visible stalls, and memory growth. |

For performance, assess frame pacing against the **measured** refresh interval (`1000 / Hz` milliseconds), not a forced 120 fps target. Proposed gate to validate during the spike: at least 95% of UI and raster frame timings fit that interval after warm-up, no repeated sustained stalls, and bounded memory across repeated sessions. Investigate cold-load stalls separately. Tune or explicitly document the supported-device gate from recorded evidence; no result is promised before testing. Flutter recommends [physical-device profiling](https://docs.flutter.dev/perf/ui-performance); use its [DevTools Performance view](https://docs.flutter.dev/tools/devtools/performance) for traces. Include a slower available Android device if practical.

## 8. Open decisions and later engineering work

1. Engineering owner: record disposable-photo permission/trash behavior on supported Android versions and the intended POCO M7 Pro 5G when hardware is available. The read-only ADB check found no attached device. This does not block the delivered local install build.
2. Verify provider-specific trash support, restoration, and retention. Trash-only is fixed for this MVP; do not add permanent deletion as a fallback.
3. Measure actual active refresh mode and frame pacing; no 120 fps or other performance result is claimed.
4. Test large text, TalkBack, light/dark appearance, reduced animation, cancellation, permission revocation, process death, and limited access on supported Android versions.
5. The display name is **Hirang**, and package ID is `com.francisgiann.hirang`; trademark/store availability has not been checked. The original photo/check launcher icon is implemented; actual launcher behavior remains a separate check.
6. The saved Codex project still points to the old `sift` path. Repoint or re-add it in Codex UI to `/home/francisgiann/Giann/Programming/hirang`; no project registry was edited.

Duplicate detection, AI, cloud sync, accounts, monetization, videos, and iOS remain deferred. The requested local build is complete; platform-specific measurements and store readiness remain separate engineering follow-ups.
