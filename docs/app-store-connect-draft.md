# Execute App Store Connect draft

The E68 Swift project builds `com.executelabs.execute.native-dev`. The matching
[Execute Native Dev record](https://appstoreconnect.apple.com/apps/6823713820/distribution/info)
has Apple ID `6823713820`, SKU `execute-native-dev`, and English (U.S.) as its
primary language. Monthly and annual products for this record use
`execute_native_dev_premium_month` and `execute_native_dev_premium_annual`.
The original Execute app, `com.executelabs.execute`, is a separate record with
its own products. Confirm the intended public listing and signed build identity
with the owner before finalizing which record will be submitted. The repository
records the native identity as temporary. [Native setup and product mapping](../ios-native/README.md#resolve-the-native-dev-configuration)

## Listing copy

**Subtitle**

Workout & nutrition planner

**Description**

Execute brings workout planning, nutrition tracking, and daily check-ins
together. Plan your training, log workouts and meals, and review your activity
over time. View your goals and use saved plans to organize your next session.
An optional Execute Premium subscription unlocks additional planning and
nutrition tools.

**Keywords**

`workout,fitness,training,nutrition,meal planner,food log,exercise,goals,recovery`

**Privacy and support**

The approved privacy policy URL is [executelabs.ca/privacy](https://executelabs.ca/privacy).
The native legal reader lists `privacy@executelabs.ca` for privacy and
`support@executelabs.ca` for support. Confirm the public Support URL displays
current contact information before using it in the listing. Apple requires a
support link and privacy policy link. [App Review](https://developer.apple.com/app-store/review/)

## Review notes draft

> Execute is a fitness and performance app for organizing training, nutrition
> and recovery. The Home, Train, Track, Nutrition and Plan tabs let reviewers
> navigate the app. An optional Execute Premium subscription is available
> through Profile → Premium & Billing. Open that screen from the supplied
> demo account to view the monthly and annual plans and the Restore Purchases
> action.

Confirm these steps in the exact signed candidate before submission. Add the
release build and final device/OS evidence. Once enabled and verified, add
Profile → Delete Account to the review notes. Include a monitored review
contact. The native app currently offers email one-time codes and Apple and
Google sign-in. Provide a dedicated, functioning review account with an expired
subscription and an independently usable sign-in route. If a secure reviewer
login is unavailable, Apple's rules allow a full demo mode with prior approval
in applicable circumstances. Existing QA identities, one-time codes and
personal accounts are unsuitable reviewer credentials.
[Complete Review](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/)
[Guideline 2.1](https://developer.apple.com/app-store/review/guidelines/#app-completeness)

## App Privacy worksheet

Candidate categories for owner verification against deployed behavior and
vendor retention. Apple requires responses covering third-party partners as
well as first-party collection. [Apple's data categories](https://developer.apple.com/app-store/app-privacy-details/)

| Candidate category | E68 source evidence |
| --- | --- |
| Name, Email Address, User ID | Supabase Auth and profile records use account email, display name and owner UUID. The RevenueCat client uses the signed-in email as its app user ID. Confirm how Apple and Google account fields are retained. |
| Health and Fitness | Owner-scoped workouts, body measurements, nutrition and recovery inputs are persisted. Relevant inputs can also reach AI when a user requests analysis or guidance. |
| Purchase History | Apple In-App Purchase and RevenueCat deliver subscription status and purchase metadata. The shared backend also reconciles Stripe web subscriptions. Confirm which information is collected from this signed iOS version. |
| Photos or Videos and Other User Content | Food Capture sends photo input for optional analysis. User-entered notes and optional PDF plan imports can reach the backend and OpenAI. Confirm which transferred content meets Apple's collection definition and its retention at each destination. |
| Diagnostics, usage and device information | The existing policy says limited technical and interaction data may be used to operate and troubleshoot the service. Confirm data types and purposes from the final archive and observed SDK or backend behavior before choosing labels. |

The app's privacy manifest declares required-reason UserDefaults access. The
release lockfile pins Supabase Swift 2.55.1, RevenueCat 5.87.1 and Swift Crypto
4.5.1. Review the final archive's aggregated manifests and actual service
settings before attesting to tracking, linkage, diagnostics or data retention.
Inspect Supabase and its email provider, Apple and Google sign-in,
RevenueCat, OpenAI, Open Food Facts and any Stripe data actually exposed to
or collected through the app. Record finalized labels only after owner review.
[App Privacy publishing instructions](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)

Apple's Guideline 5.1.2(i) requires explicit permission and clear disclosure
before sharing personal data with third-party AI. The current legal view
describes AI processing generally. The deployed candidate still needs
verification of named-provider disclosure and an explicit consent step before
personal information or attachments leave the device. Relevant paths include
photo analysis, PDF import and personalized coaching inputs. Account deletion
wording also needs to match the enabled release route.
[Apple's privacy guidelines](https://developer.apple.com/app-store/review/guidelines/#privacy)

## Screenshots and final attachment

The two subscription-review screenshots were historically saved on the monthly
and annual product records. Those attachments belong to the IAP review fields.
Verify both server-hosted attachments still appear. The listing also needs a
version-level iPhone screenshot set. Capture the exact signed candidate using
disposable synthetic content, with Home, Train, Nutrition and Plan as the main
screens. Apple accepts large Dynamic Island portrait sizes including 1320 ×
2868, 1290 × 2796 and 1260 × 2736 pixels. Use the slot shown for the release
record and the final device families. [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

After final build verification, include the reviewed app version and the
appropriate first-submission subscriptions in the same draft submission.
[Submitting subscriptions](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)
