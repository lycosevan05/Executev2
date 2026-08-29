# Native Execute Foundation

This directory is a standalone SwiftUI app. `ios/App` remains the Capacitor iOS application and must not be used as a source directory for native migration work.

## Deployment target

The native target is iOS 16.0. This enables Swift Charts for the existing insights/progress experience while keeping a broader device floor than iOS 17. The foundation therefore uses `ObservableObject` and `@Published`; future iOS 17-only Observation adoption is intentionally deferred.

## Local configuration

1. Copy `Configuration/Local.xcconfig.example` to `Configuration/Local.xcconfig`.
2. Fill in `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `REVENUECAT_API_KEY` from the existing client configuration.
3. Keep `AUTH_CALLBACK_SCHEME = com.executelabs.execute.native-dev` for this temporary bundle identifier.
4. Add `com.executelabs.execute.native-dev://login-callback` to Supabase Auth redirect URLs before testing OAuth.

`Local.xcconfig` is ignored. It may contain public mobile client keys, never Supabase service-role, OpenAI, Stripe secret, webhook secret, or private backend keys.

## Core rules

- `BackendRow` retains the database envelope and raw `data jsonb` payload. `EntityRecord<Payload>` supplies a typed view without discarding unknown JSON properties.
- New feature models use optional properties for legacy tolerance and add a representative typed payload beside tests before becoming a production dependency.
- Supabase remains the source of truth. The client sends authenticated requests under existing RLS and uses `patch_record` for shallow JSONB updates.
- `UserScopedCacheStore` separates every user by UUID, serves fresh/stale values, supports optimistic snapshots, and rolls back on failed writes. A realtime self-echo carrying the matching local mutation marker confirms rather than replaces local state.
- Realtime feature repositories own their subscriptions and cancel them when their feature disappears. A later feature migration should write the optimistic value first, then reconcile the resulting realtime row through the cache store.
- RevenueCat uses the existing email as `appUserID` so its webhook continues to map subscriptions to `user_subscriptions`. It does not write that table from iOS.
- `invoke-llm` remains the only AI boundary. The native client never has an OpenAI API key.

## Deferred integrations

The foundation includes typed auth, generic entity CRUD, `patch_record`, Edge Function invocation, cache consistency, AI response normalization, typed navigation, and RevenueCat entitlement state. Feature-specific realtime channel wiring, storage upload call sites, StoreKit purchase UI, and all product screens are deferred to their respective parity phases. The existing Capacitor behavior remains the reference contract.

## RevenueCat development setup

The temporary bundle identifier `com.executelabs.execute.native-dev` requires a matching App Store Connect app and RevenueCat app/API key (or a deliberate test configuration). Configure the documented `default` offering, `$rc_monthly`, `$rc_annual`, and `premium` entitlement there; do not assume production products attach to the temporary app automatically.
