# RevenueCat + App Store Connect — Subscription Setup (Execute Performance)

> **Purpose of this file:** Context handoff for Claude Code. It documents the
> server-side / dashboard configuration for in-app subscriptions in the
> **Execute Performance** iOS app, so that work on the StoreKit / RevenueCat
> *client integration* uses the exact identifiers already provisioned. This
> describes the **store + RevenueCat dashboard state**, not app code. No code
> has been written against this config yet.

_Last updated: 2026-06-02. Monetization stack: **Apple App Store + RevenueCat**, **StoreKit 2** (RevenueCat iOS SDK v5+)._

---

## TL;DR — what an integration needs to know

- The app uses **RevenueCat** as the subscription layer in front of the App Store.
- Read the current offering via `Purchases.shared.getOfferings()` → `offerings.current`.
- The current offering is **`default`** and contains two packages:
  - `$rc_monthly` → product `execute_premium_month`
  - `$rc_annual`  → product `execute_premium_annual`
- Gate premium features on the **`premium`** entitlement:
  `customerInfo.entitlements.active["premium"] != nil`.
- Configure the SDK with the **public Apple SDK API key** (see *Outstanding* — not yet retrieved into code).
- Everything store-side is provisioned and the **Paid Apps Agreement is Active**, so purchases (incl. sandbox) are not blocked.

---

## Identifiers reference (the canonical list)

| Thing | Value | Notes |
|---|---|---|
| App name | Execute Performance | App Store Connect app |
| ASC app ID | `6774024357` | from ASC URL |
| RevenueCat project ID | `7415d2f3` | from dashboard URL |
| Subscription group | `execute_premium` | group ID `22118228` |
| Subscription group display name | Execute Performance Premium | English (U.S.) localization |
| Monthly product ID | `execute_premium_month` | 1 month, auto-renewable |
| Annual product ID | `execute_premium_annual` | 1 year, auto-renewable |
| Entitlement identifier | `premium` | ⚠️ verify exact string in dashboard (see note) |
| Offering identifier | `default` | marked **Current**; REST id `ofrng8a008f1895` |
| Monthly package id | `$rc_monthly` | RevenueCat predefined |
| Annual package id | `$rc_annual` | RevenueCat predefined |
| RC app config REST identifier | `appfcd5594b1e` | identifies the Apple app config in RC; **not** the SDK key |

> ⚠️ **Entitlement string:** the intended identifier is `premium`. The
> attachment to both products was confirmed in the dashboard, but the exact
> identifier string should be re-read from **Product catalog → Entitlements**
> before hardcoding it, since a mismatch silently breaks unlocking.

---

## 1. App Store Connect — subscriptions

A single subscription group, `execute_premium`, containing two auto-renewable
subscriptions:

| Level | Reference name | Product ID | Duration | Status |
|---|---|---|---|---|
| 1 | Execute Premium — Monthly | `execute_premium_month` | 1 month | Ready to Submit |
| 2 | Execute Premium — Annual | `execute_premium_annual` | 1 year | Ready to Submit |

- Both carry required metadata + pricing and reached **Ready to Submit**.
- Localization (English U.S.) present at the group level; app name display
  "Execute Performance".
- **Important for first release:** Apple requires the *first* subscription to be
  submitted **with a new app version** — i.e. selected in the app version's
  "In-App Purchases and Subscriptions" section before that version goes to App
  Review. "Ready to Submit" is the pre-submission state, not "live". Subsequent
  subscriptions can be submitted independently afterward.

## 2. App Store Connect ↔ RevenueCat credentials

In RevenueCat **Project settings → Apps & providers → Execute Performance (Apple)**:

- **In-App Purchase Key** (`.p8`): uploaded, **Valid credentials**. Required for
  StoreKit 2 / RC iOS SDK v5+; without it transactions fail to record.
  (Apple file prefix `SubscriptKey_…`.)
- **App Store Connect API Key** (`.p8`): uploaded, **Valid credentials**. Enables
  product import + automatic price sync. (Apple file prefix `AuthKey_…`.)
- **App-Specific Shared Secret (Legacy):** intentionally empty — only needed for
  StoreKit 1, not used here.
- Both keys generated in App Store Connect under **Users and Access →
  Integrations** (In-App Purchase tab and App Store Connect API tab; same Issuer
  ID for both).

## 3. RevenueCat — products

Both App Store products imported and visible under the Apple **Execute
Performance** app (distinct from the auto-generated **Test Store** sample
products, which are NOT used in production):

- `execute_premium_annual` — Execute Premium — Annual — Ready to Submit
- `execute_premium_month` — Execute Premium — Monthly — Ready to Submit

## 4. RevenueCat — entitlement

- Entitlement **`premium`** created and attached to **both** products
  (`execute_premium_month`, `execute_premium_annual`).
- This is the access gate. A purchase only unlocks features if the entitlement
  is attached — confirmed attached in dashboard.

## 5. RevenueCat — offering & packages

- Offering **`default`** (REST id `ofrng8a008f1895`) is set as **Current**
  (the app reads `offerings.current`).
- Packages point at the **real Apple products** (not Test Store):
  - **Monthly** `$rc_monthly` → `execute_premium_month` (Execute Premium — Monthly)
  - **Yearly**  `$rc_annual`  → `execute_premium_annual` (Execute Premium — Annual)
- ⚠️ A **`$rc_lifetime`** package exists in the scaffold but there is **no
  lifetime product**. Its state was not confirmed — it should be removed or
  verified empty so a paywall does not render a phantom option.

## 6. Business / Paid Apps Agreement

All Active (purchases, including sandbox, are not blocked at the agreement layer):

- **Paid Apps Agreement:** Active (effective Jun 1 2026 – May 11 2027), all
  countries/regions.
- **Free Apps Agreement:** Active.
- **Bank account:** BMO (CAD bank currency, USD royalty currency) — Active.
- **Tax forms:** Canadian GST/HST Form 506 and U.S. Certificate of Foreign
  Status — both Active.
- Legal entity: individual (Vancouver, BC, Canada).

---

## Client integration notes (for when code is written)

- **SDK:** RevenueCat `purchases-ios` v5+ (StoreKit 2 path).
- **Configure:** `Purchases.configure(withAPIKey: <public Apple SDK key>)`.
  The SDK key is the **public** app-specific key from RevenueCat **API keys**,
  *not* the REST identifier `appfcd5594b1e` and *not* any `.p8`.
- **Fetch offerings:** `Purchases.shared.getOfferings()`, then use
  `offerings.current` (→ `default`). Render packages by reading
  `current.monthly` / `current.annual` (or by identifier `$rc_monthly` /
  `$rc_annual`).
- **Purchase:** `Purchases.shared.purchase(package:)`.
- **Gate access:** check `customerInfo.entitlements.active["premium"]`.
- **Restore:** wire up `Purchases.shared.restorePurchases()`.
- **Testing:** in-app purchases require a **physical device** + a **sandbox
  tester** account; the simulator does not support StoreKit purchases.

---

## Status & outstanding items

**Complete (checklist steps 1–6):**
- [x] 1 — Two auto-renewable subscriptions in one group, Ready to Submit, product IDs noted
- [x] 2 — ASC connected to RevenueCat (In-App Purchase Key + App Store Connect API Key, both valid)
- [x] 3 — Both products imported into RevenueCat
- [x] 4 — `premium` entitlement created and attached to both products
- [x] 5 — `default` offering with `$rc_monthly` + `$rc_annual` packages on real products, set as Current
- [x] 6 — Paid Apps Agreement Active (bank + tax forms Active)

**Outstanding / recommended (not blocking config, but needed before shipping):**
- [ ] Retrieve the **public SDK API key** from RevenueCat → API keys and wire into `Purchases.configure`.
- [ ] Resolve the **`$rc_lifetime`** package (delete or confirm empty).
- [ ] Configure **Apple Server-to-Server (App Store Server) notifications** in RevenueCat (renewals/cancellations/refunds sync). Currently "No notifications received".
- [ ] **Sandbox test** both purchases on a physical device; confirm the `premium` entitlement activates end to end.
- [ ] Submit the **first subscription with a new app version** to App Review (Apple requirement).
- [ ] Confirm RevenueCat account **email verification** (dashboard banner outstanding).
- [ ] Re-verify the exact **entitlement identifier string** before hardcoding.

---

## Things deliberately NOT in this file

- No API keys, shared secrets, `.p8` contents, or other credentials. Those live
  in App Store Connect and the RevenueCat dashboard; retrieve them there.
