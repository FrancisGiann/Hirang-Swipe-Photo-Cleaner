# Hirang visual review

Reviewed on 10 October 2026 for the 1.0.4 (5) Android install build. The review inspected the actual PNG pixels after the final successful Flutter suite, including the held KEEP and MARK FOR REMOVAL feedback, clean snapback, clarified system-confirmation dialog, generated sample deck, photo layout, filters, narrow large-text layout, and menu shadow.

## Method and coverage

`test/visual_review_test.dart` renders the real onboarding, home, marked-review and dialog widgets through the shared app themes. The theme-specific captures render the actual SiftApp, including the saved palette and app navigator. It uses the existing Flutter widget-test renderer, cached Roboto and Material Icons fonts, normal shadows, generated photo artwork, fake media metadata, and a fake platform gateway. Normal-layout swipe captures and hold/reversal/cancellation regressions use real test-pointer events. The narrow dark/text-scale-2 swipe captures drive the same production gesture callbacks directly to isolate rendering, after test-pointer dispatch failed in that fixture; they do not establish narrow-screen pointer routing on hardware. It captures the app including overlays through a `RepaintBoundary`; it does not use a browser recreation or personal photos. No additional package or software was installed.

9 capture test groups passed within the final **60-test Flutter suite**. Captures 01–32 use 393 × 886 logical pixels at device-pixel ratio 2 (786 × 1772 PNGs), except the narrow deck at 360 × 812 logical pixels (720 × 1624 PNG) and captures 31–32 at 320 × 720 logical pixels (640 × 1440 PNG). The narrow deck and welcome/practice large-text captures use text scale 1.5. Welcome and full-library deck have dark-theme captures; the held mark-intent and snapback captures 31–32 use dark theme and text scale 2. Other supporting states are captured at normal text in the light theme. A separate focused layout test also passed at 320 logical pixels wide and text scale 2; this is an overflow check, not a screenshot of every state.

The visual set verifies representative screens, not every combination of width, text size, theme and state. Android's permission, trash approval, settings and launcher UIs were not rendered or exercised on hardware. The icon previews check the artwork under representative masks, not a specific phone launcher's behavior. TalkBack, system insets/gestures, physical-device frame pacing and provider behavior remain engineering follow-ups.

## Screen evidence

| Capture | State inspected |
| --- | --- |
| [01](build/visual-review/01-welcome-393-light.png) | First-launch welcome, Skip, and Continue |
| [02](build/visual-review/02-practice-393-light.png) | Generated practice card and balanced actions |
| [03](build/visual-review/03-practice-marked-393-light.png) | Practice marking and Undo feedback |
| [04](build/visual-review/04-trash-explanation-393-light.png) | Marking versus system trash and recovery limits |
| [05](build/visual-review/05-choose-photos-393-light.png) | Explicit photo access, sample, or later choice |
| [06](build/visual-review/06-full-library-deck-393-light.png) | Compact header/progress, contained photo, metadata, Mark/Keep/Undo |
| [07](build/visual-review/07-filter-sheet-393-light.png) | Scrollable month/album/screenshots sheet with All months/All albums |
| [08](build/visual-review/08-photo-details-393-light.png) | Full filename and photo details outside the deck |
| [09](build/visual-review/09-marked-review-393-light.png) | Marked-item grid and estimated selected size |
| [10](build/visual-review/10-trash-confirmation-393-light.png) | Complete in-app confirmation with Review system confirmation before OS approval |
| [11](build/visual-review/11-full-library-narrow-360-large-text.png) | 360-pixel-wide deck at text scale 1.5 |
| [12](build/visual-review/12-full-library-deck-393-dark.png) | Dark full-library deck |
| [13](build/visual-review/13-limited-access-393-light.png) | Actionable selected-photo access notice |
| [14](build/visual-review/14-photo-access-off-393-light.png) | Denied/no photo access |
| [15](build/visual-review/15-empty-library-393-light.png) | Empty accessible library and refresh |
| [16](build/visual-review/16-library-error-393-light.png) | Query failure with retry; not reported as an empty library |
| [17](build/visual-review/17-startup-loading-393-light.png) | Startup recovery/loading gate |
| [18](build/visual-review/18-saved-review-retry-393-light.png) | Unreadable saved review with retry |
| [19](build/visual-review/19-verified-result-393-light.png) | Verified trash result with no remaining photo |
| [20](build/visual-review/20-photo-options-393-light.png) | Consistent photo-options menu and introduction replay |
| [21](build/visual-review/21-how-it-works-393-light.png) | Scrollable help and safety guidance |
| [22](build/visual-review/22-welcome-large-text-393-light.png) | Large-text welcome |
| [23](build/visual-review/23-practice-large-text-393-light.png) | Large-text practice with visible Continue footer |
| [24](build/visual-review/24-welcome-393-dark.png) | Dark welcome |
| [25](build/visual-review/25-partial-result-393-light.png) | Partial result with only the remaining photo |
| [26](build/visual-review/26-cancelled-result-393-light.png) | Cancelled request with unresolved marks retained |
| [27](build/visual-review/27-sample-deck-393-light.png) | Permission-free generated sample deck, explicitly fictional |
| [28](build/visual-review/28-swipe-mark-intent-393-light.png) | Held left drag with red mark label and icon; no decision yet |
| [29](build/visual-review/29-swipe-keep-intent-393-light.png) | Held right drag with green keep label and check; reversal updates the intent |
| [30](build/visual-review/30-swipe-snapback-393-light.png) | Short release returns the same card with no intent or decision |
| [31](build/visual-review/31-swipe-mark-dark-large-text-320.png) | Narrow dark-theme held mark at text scale 2 |
| [32](build/visual-review/32-swipe-snapback-dark-large-text-320.png) | Narrow dark-theme short-release snapback at text scale 2 |

## Photo clarity evidence

The 1.0.3 fix adds one capture group using 360 × 800 logical pixels at DPR 3, producing **1080 × 2400** PNGs. A generated 1800 × 2700 source contains fine print, narrow line pairs and checker patterns. The fake gateway returns generated derivatives for the requested 64-pixel bucket, under the same 2048-edge/3-million-pixel sizing ceiling; it does not feed an unrestricted original into the rendered app. Request/output dimensions are asserted. Full renders and native-pixel crops were inspected: fine print is readable and narrow lines stay separated in both views.

| Capture | State inspected |
| --- | --- |
| [33](build/visual-review/photo-clarity/33-photo-detail-deck-360-dpr3.png) | Source-sized card at DPR 3 with detailed synthetic fixture |
| [34](build/visual-review/photo-clarity/34-photo-detail-viewer-360-dpr3.png) | Expanded contained preview with readable text/checkers and Close action |

A user-provided screenshot was inspected as a reference only. Automated tests and captures use generated fixtures and fake metadata; no personal library was scanned or modified. Native source decoding, EXIF on supported Android versions, provider fallback latency and hardware frame pacing have not been exercised on a device. These captures establish rendered detail at the stated viewport, not hardware smoothness.

## Three-theme evidence

The saved visual picker was inspected in Amihan, Dapithapon and Hatinggabi. Each palette has welcome, generated practice, sample deck, marked review, help, Settings, query-error and in-app trash-confirmation captures at 393 × 886 logical pixels and DPR 1. The confirmations use generated metadata and a fake gateway; they do not exercise Android approval. Theme switching, failed saves, preserved review decisions, restart persistence, narrow large text and zero-duration theme changes also have focused checks.

The generated card interior is exactly identical across the three deck captures: 168,300 pixels compared. This supports the no-tint rendering check; original media bytes are never rewritten. Keep remains green and Mark red in every palette. Shared token tests target 4.5:1 for representative text and 3:1 for controls/icons, rather than inferring contrast from antialiased screenshot edges.

| Theme | Actual screen captures |
| --- | --- |
| Amihan | [35 Welcome](build/visual-review/35-amihan-welcome.png), [36 Practice](build/visual-review/36-amihan-practice.png), [37 Deck](build/visual-review/37-amihan-deck.png), [38 Marked review](build/visual-review/38-amihan-marked.png), [39 Help](build/visual-review/39-amihan-help-dialog.png), [40 Settings](build/visual-review/40-amihan-settings.png), [41 Query error](build/visual-review/41-amihan-query-error.png), [42 App confirmation](build/visual-review/42-amihan-trash-confirmation.png) |
| Dapithapon | [43 Welcome](build/visual-review/43-dapithapon-welcome.png), [44 Practice](build/visual-review/44-dapithapon-practice.png), [45 Deck](build/visual-review/45-dapithapon-deck.png), [46 Marked review](build/visual-review/46-dapithapon-marked.png), [47 Help](build/visual-review/47-dapithapon-help-dialog.png), [48 Settings](build/visual-review/48-dapithapon-settings.png), [49 Query error](build/visual-review/49-dapithapon-query-error.png), [50 App confirmation](build/visual-review/50-dapithapon-trash-confirmation.png) |
| Hatinggabi | [51 Welcome](build/visual-review/51-hatinggabi-welcome.png), [52 Practice](build/visual-review/52-hatinggabi-practice.png), [53 Deck](build/visual-review/53-hatinggabi-deck.png), [54 Marked review](build/visual-review/54-hatinggabi-marked.png), [55 Help](build/visual-review/55-hatinggabi-help-dialog.png), [56 Settings](build/visual-review/56-hatinggabi-settings.png), [57 Query error](build/visual-review/57-hatinggabi-query-error.png), [58 App confirmation](build/visual-review/58-hatinggabi-trash-confirmation.png) |

## Launcher evidence

The original icon is a green photo frame/landscape with an orange check. It has density-specific legacy PNGs, adaptive and round resources, and a monochrome foreground. Foreground artwork stays within the adaptive safe region; the monochrome path preserves transparent cutouts. The artwork was also inspected at the small legacy size.

- [Squircle preview](build/visual-review/launcher-squircle.png)
- [Round preview](build/visual-review/launcher-round.png)
- [Monochrome preview](build/visual-review/launcher-monochrome.png)

## Reproduce the screen captures

From the project directory with the existing configured Flutter toolchain:

```sh
flutter test test/visual_review_test.dart --no-pub --concurrency=1 --reporter expanded
```

The capture test currently loads fonts from this Fedora computer's existing Flutter cache path. Another development machine must point that fixture loader at its corresponding cache before reproducing. PNGs are generated under `build/visual-review/`; keep the evidence when cleaning build output if it is needed later.
