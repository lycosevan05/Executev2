# App Store Compliance Audit + Remediation Plan

> **How to use this file:** Save it as `.claude/commands/appstore-audit.md` in your repo root. It then becomes the `/appstore-audit` slash command in Claude Code. **Run it in Plan Mode** (press `Shift+Tab` until you see *plan mode on*) so the audit stays strictly read-only and you approve the plan before any edit happens. You can also just paste the body below directly into a normal prompt.

---

You are a senior iOS release engineer auditing a **Capacitor-wrapped React/Vite** project for Apple App Store acceptance. Your job has two phases:

1. **Audit** the actual repository against the rubric below — grounded in real files, not assumptions.
2. **Produce a remediation plan** that, if executed, would make this app pass App Store review.

**Operating rules:**
- This is a **read-only audit**. Do not modify, create, or delete any files in this phase. Investigate, then propose. Wait for my approval before implementing anything.
- **Every finding must cite evidence**: the exact file path and line(s), or the explicit absence of an expected file. No generic advice. If you can't find evidence either way, say so and list it as "needs manual verification" rather than guessing.
- Apple's requirements change yearly. The hard gates below reflect the state as of mid-2026, but **verify the current minimum Xcode/SDK and privacy requirements** against Apple's "Upcoming Requirements" and App Store Review Guidelines if you have web access; flag if you cannot.
- Be specific to *this* codebase. Read `package.json`, `capacitor.config.*`, the entire `ios/App` directory, the asset catalog, entitlements, and the Vite build config before writing a single finding.

## Phase 0 — Build a map of the project first

Read and summarize these before auditing. List what you found (versions, plugins, config values) so the audit is anchored to reality:

- `package.json` and lockfile — Capacitor version, every `@capacitor/*` and `@capacitor-community/*` and Cordova plugin, and any SDK with native code (analytics, auth, payments, push, ads).
- `capacitor.config.ts` / `capacitor.config.json` — especially `server.url`, `server.cleartext`, `appId`, `appName`, `ios` config.
- `ios/App/App/Info.plist` — all keys, especially usage-description strings, ATS settings, URL schemes, background modes, `ITSAppUsesNonExemptEncryption`.
- `ios/App/App/PrivacyInfo.xcprivacy` — does it exist, is it in the App target's build resources, what does it declare.
- `ios/App/App/App.entitlements` — capabilities declared.
- `ios/App/App/Assets.xcassets` — app icon set (incl. 1024px marketing icon) and launch screen / storyboard.
- `ios/App/Podfile` + `Podfile.lock`, deployment target, and the project's `IPHONEOS_DEPLOYMENT_TARGET`.
- `vite.config.*` and the built `dist/` output assumptions — confirm web assets are bundled locally, not loaded from a remote origin.

## Phase 1 — Audit rubric

Classify every finding by **severity**: 🔴 Blocker (app cannot be uploaded, or near-certain rejection) · 🟠 High (likely rejection) · 🟡 Medium (possible rejection / reviewer discretion) · ⚪ Outside-repo (lives in App Store Connect, not the code — flag for me to handle).

### A. Hard submission gates — binary, will block upload
- **Build toolchain.** Confirm the project can build with the **currently required Xcode/iOS SDK** (as of mid-2026: Xcode 26 / iOS 26 SDK, enforced since Apr 28 2026 — verify it's still current). Flag an outdated Capacitor major version (privacy-manifest tooling needs a recent Capacitor; check release notes for the current major). Note the deployment target.
- **Privacy manifest (`PrivacyInfo.xcprivacy`).** Must exist and be added to the App target's resources. For **every Required-Reason API** used by the app and by each native plugin, it must declare the API category and a valid reason code. Map each installed plugin to the categories it touches — e.g. `@capacitor/preferences` → `NSPrivacyAccessedAPICategoryUserDefaults`; `@capacitor/filesystem` → file-timestamp / disk-space categories; plugins reading boot time → `SystemBootTime`. Look up the correct reason code per Apple's "Describing use of required reason API" docs; do not invent codes. Also check `NSPrivacyTracking`, `NSPrivacyTrackingDomains`, and `NSPrivacyCollectedDataTypes` are present and accurate (keys must exist even if empty). Note whether each third-party SDK ships its own manifest or whether you must declare on its behalf.
- **Permission usage strings.** For every permission any installed plugin can trigger, `Info.plist` must contain a specific, human-meaningful description string (`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `NSMicrophoneUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSContactsUsageDescription`, `NSFaceIDUsageDescription`, `NSUserTrackingUsageDescription`, `NSBluetoothAlwaysUsageDescription`, `NSCalendarsUsageDescription`, etc.). Boilerplate like "This app needs access" is a rejection risk — flag vague strings.
- **App icon & launch screen.** Full icon set present, 1024×1024 marketing icon with **no alpha channel / transparency**. Launch screen/storyboard present and not a blank mismatch with first frame.
- **App Transport Security.** No `NSAllowsArbitraryLoads = true` (or justify every ATS exception). All network traffic HTTPS. `server.cleartext` must not be enabled for production.
- **Encryption declaration.** `ITSAppUsesNonExemptEncryption` set in `Info.plist` to avoid the upload-time export-compliance prompt.

### B. Guideline 4.2 — Minimum Functionality (the #1 killer for Capacitor apps)
This is the single highest-probability rejection for a web-wrapped app. Audit hard:
- **`server.url` must NOT point to a live website.** If `capacitor.config` loads the app from a remote URL, that is a near-certain "this is just your website" rejection. Web assets should be **bundled locally** in the binary. Flag as 🔴 if remote.
- **Native-app feel.** Look for evidence the app is more than a Safari shortcut: a real native splash screen, status-bar + safe-area/notch handling, disabled browser-style text selection/zoom where inappropriate, native navigation/gestures, offline handling, and at least one genuine native capability (Push Notifications, Haptics, Biometrics, Share Sheet, Camera, etc.). List which native plugins are actually wired up vs. merely installed.
- **External-link behavior.** Primary navigation should not be links that turn the app into a web browser. Flag in-app links that open arbitrary external web content as core flow.
- Summarize concretely: *"Here is why a reviewer might call this a repackaged website, and here is the specific evidence."*

### C. Privacy & legal
- **Account deletion (5.1.1(v)).** If the app supports account creation, it must offer in-app account deletion. Search the code for sign-up/login; if present, verify a deletion path exists.
- **Sign in with Apple.** If the app offers third-party social login (Google/Facebook/etc.), Sign in with Apple is commonly expected as an option — flag for review.
- **Privacy policy.** A reachable privacy policy link should exist in-app (and in ASC). Flag if missing in the UI.
- **App Tracking Transparency.** If any tracking/IDFA/ad SDK is present, an ATT prompt + `NSUserTrackingUsageDescription` are required, and tracking domains must appear in the privacy manifest.

### D. Payments — Guideline 3.1.1
- Determine what the app sells. **Digital goods/subscriptions consumed in-app must use Apple In-App Purchase** — an external payment flow (e.g. Stripe inside the webview) for digital content is a rejection. Physical goods/services may use external payment. Subscriptions need a visible **Restore Purchases** path. Classify based on what this app actually does, and flag the risk explicitly.

### E. Completeness & stability — Guideline 2.1
- No placeholder/lorem content, no dead links, no console errors thrown in the webview on key flows, backend reachable. If the app is login-gated, note that **demo credentials must be supplied in App Review notes** (outside-repo, but flag it).

### F. Capacitor-specific gotchas
- Confirm **WKWebView** is used (Capacitor default) and there are **no `UIWebView` references** anywhere (banned).
- **Unused capabilities/permissions** are a rejection trigger. Cross-check `App.entitlements` and `Info.plist` background modes / capabilities against what the code actually uses — declaring Push, Associated Domains, Background Modes, etc. without using them gets rejected.
- For each installed plugin: is it actually used in the JS/TS code? Remove-candidates that only add permission surface.

### G. Outside-repo items (⚪ — flag, don't try to fix in code)
List these as a checklist for me to handle in App Store Connect: screenshots for current device sizes; description with no mention of other platforms/beta/placeholder; **age-rating answers under Apple's new age-rating system**; **Privacy Nutrition Labels that match actual data collection**; export compliance; **EU trader status (DSA)** if distributing in the EU; and review notes documenting the native features + demo login.

## Phase 2 — Output format

Produce, in this order:

1. **Project map** — the versions/plugins/config values you found in Phase 0.
2. **Findings table** — columns: `Severity | Category | Finding | Evidence (file:line or "missing X") | Why Apple rejects this`. Sort by severity, blockers first.
3. **Remediation plan** — an ordered, dependency-aware checklist. For each item: the exact files to change, what the change is (show the target state — e.g. the manifest keys to add, the `Info.plist` strings to write, the `capacitor.config` change), and how to verify it. Group into "must fix before submission" vs. "should fix" vs. "App Store Connect tasks (you handle)".
4. **The 4.2 narrative** — a short, blunt paragraph on whether this app currently reads as "app-like enough," and the specific native features I should add or surface to de-risk it.
5. **Open questions** — anything you couldn't determine from the repo that changes the plan (e.g. "does the app sell digital subscriptions?" "do you offer Google login?").

Do not start implementing. End by asking me to approve the plan (or a subset) before you make edits.
