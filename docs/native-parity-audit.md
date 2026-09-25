# Native iOS parity audit

Last reviewed: 2026-09-24

This ledger tracks the SwiftUI app against the existing Capacitor app. The Capacitor source remains a read-only behavioral reference until each required workflow is verified on a physical iPhone.

## Current native surface

| Area | Status | Native implementation | Remaining work |
| --- | --- | --- | --- |
| Startup and authentication | Partial | Native launch state, Supabase session restore, email OTP, Apple/Google OAuth, sign-out service | Validate callback handling, expiry, cancellation, and account recovery on device |
| App shell | Complete | Five native tabs, independent navigation stacks, full-screen routing, safe-area tab bar | Physical-device accessibility and rotation audit |
| Home | Partial | Native dashboard, customization, live data, cache, realtime, checklist mutations | Replace Recovery, Progress, Insights, Goals, Profile, and My Week placeholder destinations |
| Train dashboard | Partial | Today, split, library, history, native plan data | Add plan-generation/editing parity and completed-session detail |
| Workout session | Implemented, needs device QA | Native plan loading, resume, autosave, sets, reps, weight, rest timer, skip/custom exercise, notes, check-in, completion, daily-log synchronization, summary | Verify production RLS writes, readiness recalculation parity, background/termination recovery, and real-data edge cases |
| Track | Partial | Native metric logging, manage metrics, food shortcut, completion state, tracking history | Verify every Capacitor metric and history action against production data |
| Nutrition | Partial | Native date navigation, meal plan, manual and AI logging, deletion, totals | Validate AI upload/error limits, saved recipes, and all premium gates |
| Plan | Partial | Native weekly plan, blueprint, adjustments presentation | Implement plan questionnaire/generation, editable adjustments, and regeneration flow |
| Recovery | Missing | Typed route only | Build readiness check-in, score explanation, mobility/recovery plan, and persistence |
| Progress and insights | Missing | Typed routes only | Build charts, trends, goal linkage, date ranges, empty states, and sharing/export if retained |
| Goals | Missing | Typed route only | Build create/edit/archive goals and progress entries |
| Profile and settings | Missing | Typed route only | Build account, units, personal profile, notifications, sign-out, and account deletion |
| Billing | Missing | RevenueCat service exists; typed route only | Build paywall, restore purchases, subscription state, and entitlement error handling |
| Onboarding | Missing | Typed route only | Port the required native questionnaire and first-plan handoff |
| Legal | Missing | Typed Privacy and Terms routes | Render bundled or hosted legal content with production links |

## Release gates

- No `RoutePlaceholderView` is reachable from a production action.
- Every Capacitor workflow is marked retained, replaced, or intentionally removed.
- Production Supabase RLS, RevenueCat entitlements, OAuth callbacks, and account deletion are verified.
- Loading, empty, offline, retry, expired-session, and permission-denied states are exercised.
- Unit tests cover calculations and mutations; UI tests cover sign-in, all five tabs, workout completion, food logging, and purchase restoration.
- VoiceOver, Dynamic Type, keyboard behavior, reduced motion, safe areas, and the smallest supported iPhone pass QA.
- Debug and Release simulator builds pass; a signed device archive uploads to TestFlight.
- App icon, launch presentation, privacy strings, privacy manifest, screenshots, support URL, privacy URL, and App Store metadata are complete.

## Recommended implementation order

1. Verify the workout session against production data on a physical iPhone.
2. Build Profile, Billing, Privacy, and Terms so account and subscription management are complete.
3. Build Recovery, Goals, Progress, Insights, and My Week in that dependency order.
4. Complete onboarding and plan generation/editing.
5. Run parity QA, expand automated tests, archive, and distribute through TestFlight.
