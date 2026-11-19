# Sign in with Apple deletion staging

The native app signs in to Supabase through GoTrue's external Apple OAuth flow
and exchanges the Supabase PKCE callback code through the Swift Auth SDK. The
callback code belongs to Supabase. The SDK can return separate provider tokens
from that initial exchange, but the deletion endpoint currently receives the
Supabase bearer alone and has no durable Apple grant acquisition or storage.

- [Pinned GoTrue PKCE token exchange](https://github.com/supabase/auth/blob/v2.188.1/internal/api/token.go)
- [Supabase Sign in with Apple](https://supabase.com/docs/guides/auth/social-sign-in/auth-apple)

The isolated staged route can consume an operator-provisioned Apple grant for
the single allowlisted disposable account. The server takes its Apple subject
from the verified Auth identity and requires an exact UUID and subject match
against the trusted grant. Billing ownership, upload drain, and any configured
billing projection fence must clear before it attempts revocation. Apple
provider failures are redacted and preserve the account and data for retry.
Apple's 200 response acknowledges revocation or an already-invalid token.

For a separately authorized staged Apple acceptance run, the existing
project-and-account allowlist still applies. Use an isolated OAuth Services ID
and its registered HTTPS Supabase callback. Confirm the Services ID's primary
App ID and group are isolated from the release OAuth authorization. The StoreKit
Sandbox tester and native bundle ID do not identify this OAuth client. Have
the owner privately authorize a disposable Apple Account. Read the Apple identity's
`sub` from the verified Auth record for the allowlisted UUID. Capture any
`provider_refresh_token` directly from the initial GoTrue exchange in a
server-only flow. Supabase Auth does not retain Apple provider tokens for later
retrieval. If the initial exchange returns no Apple refresh token, stop and
use an approved fresh Apple authorization flow for that same fixture.

The `EXECUTE_STAGED_APPLE_GRANT` JSON fields are `ownerId`, `subject`, `clientId`,
`clientSecret`, and `refreshToken`. Prepare this secret in an operator-controlled
environment. Independently supply `EXECUTE_STAGED_DELETION_OWNER_UUID` and
`EXECUTE_STAGED_APPLE_AUTH_SUBJECT` from the Auth readback and
`EXECUTE_STAGED_APPLE_CLIENT_ID` from the approved Apple Services ID. From the
repository root, run the provisioning check with only these environment values
and Apple network access:

```sh
deno run --allow-env=EXECUTE_STAGED_DELETION_OWNER_UUID,EXECUTE_STAGED_APPLE_AUTH_SUBJECT,EXECUTE_STAGED_APPLE_CLIENT_ID,EXECUTE_STAGED_APPLE_GRANT \
  --allow-net=appleid.apple.com supabase/functions/deleteUserData-staged/verifyAppleGrant.ts
```

The check validates a refresh-token response from Apple. It verifies the ID
token's signature with Apple's rotating public keys, then checks the issuer,
audience, expiration and exact subject. It issues no revocation request and
prints only a success or failure message. After a pass, stage the same unchanged
JSON in the isolated runtime's secret store. Recheck if the candidate changes.
Do not require a fresh validation on deletion retries. A valid grant may already
have been revoked during an earlier request that later failed to finish cleaning
up Supabase. Remove the staged secret at the end, including after an aborted
experiment. Client requests supply no Apple token or destination. Keep tokens,
client secrets and code-exchange outputs out of console logs and test evidence.

For acceptance, confirm Apple authorization exists before the deletion. After
one approved request, verify its deletion receipt, the absence of the exact
Supabase Auth record and associated fixtures, and the removal of the exact
service authorization in the disposable Apple Account. Confirm the unrelated
witness survives. Apple may return 200 for a previously invalid grant, so verify
the provider state independently before accepting the live result.

- [Apple OAuth environment and Services ID configuration](https://developer.apple.com/documentation/signinwithapple/configuring-your-environment-for-sign-in-with-apple)
- [Apple refresh-token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)
- [Apple ID-token verification](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)
- [Supabase provider token handling](https://supabase.com/docs/guides/auth/social-sign-in)

For existing Apple accounts where no Apple credential is available, deletion
continues under Apple's documented fallback. After verifying the server's full
deletion receipt, the native app signs out and directs the user to Apple's
manual revocation instructions. Accounts with other sign-in methods also take
this path if their verified Auth record has a linked Apple identity. Unrelated
accounts make no Apple request.

- [Apple TN3194 account deletion and legacy workflow](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
- [Apple token revocation API](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)
- [Apple manual revocation instructions](https://support.apple.com/en-us/102571)

Before production rollout, acquire and validate new Apple grants server-side
against the exact Apple issuer, client audience and linked subject, then store
the revocable grant in a server-only encrypted store. Separately verify expiry,
rotation, callback/account isolation, deletion cleanup and consent-revocation
handling with a real Apple identity. Staging fixtures exercise the request and
retry contract using a mocked provider. Production grant acquisition remains
open.

## E70 isolated live result

The separate QA primary App ID, Services ID and signing key used the E67
deletion-rehearsal callback. The owner approved private sign-in with their
ordinary Apple Account for this one QA authorization. Apple Account settings
showed distinct Execute and Execute QA Revocation entries before deletion.
The first server-side Supabase PKCE exchange returned an Apple refresh grant.
The preflight validated its signature, exact Services ID and Auth identity.

The hosted staged handler first returned HTTP 503 while disabled. Once armed
for the exact QA UUID, it returned a successful deletion receipt with Apple
revocation. A second provider request found the same previously valid grant
rejected with `invalid_grant`. Apple Account settings showed the regular
Execute entry after the QA entry disappeared. Independent SQL confirmed the
synthetic goal and the isolated Auth user were gone.

The temporary staged function and its four secrets were withdrawn. The
isolated database guard catalog matched the original snapshot after reversal.
The existing production OAuth client and callback serve the release path.
The E70 verification applies to the QA OAuth client and hosted rehearsal.

## E72 capture and custody candidate

`appleGrantCapture` accepts a single Apple refresh token over the
authenticated connection to the exact configured Supabase project. The
server reads the Apple subject from the authenticated Supabase user and
rechecks it in Auth under the database owner lock. The Apple refresh call
must return a signed ID token with the expected issuer, service audience,
subject and expiry. The endpoint confirms storage with HTTP 204.

The native opt-in uses the refresh token returned by the first Supabase PKCE
exchange. It hands that credential to the configured HTTPS endpoint from
memory and strips provider tokens from SDK session persistence. The native
retry uses the original acknowledged Supabase session and code-exchange result.
An Apple callback with an available token finishes sign-in after custody is
confirmed. A change of account invalidates the pending callback. A cold
relaunch after a failed handoff requires a fresh Apple sign-in. Apple accounts
where Supabase supplies no token retain the documented manual fallback.

The vault encrypts each token with AES-256-GCM and additional authenticated
data linking the project, owner UUID, Apple subject, client ID, grant ID and
key ID. HKDF derives separate encryption and fingerprint keys. A keyed
fingerprint recognizes a previously verified token without another Apple
refresh request. Each distinct verified grant remains available for
revocation. Database table access is private and the scoped RPCs require the
service role.

Deletion closes capture under the Auth owner lock before issuing the Apple
requests. It authenticates all encrypted records before contacting Apple.
Each accepted revoke removes that grant's ciphertext. A durable completion
marker remains until Auth cleanup, so a later deletion retry can return the
same Apple outcome. A failed provider response or database acknowledgment
retains the corresponding ciphertext. An Apple 200 also covers an already
invalidated token according to Apple's revocation contract.

### Scoped configuration and acceptance

Apply `supabase/tests/account-deletion/apple-grant-custody.sql` only on the
approved test project. The staged delete endpoint can consume captured
grants when custody is enabled. Its existing operator-provisioned E70 mode
remains available with custody disabled. Provide these settings privately:

- `EXECUTE_APPLE_GRANT_MODE=enabled` and `EXECUTE_APPLE_GRANT_PROJECT_URL`
  equal to the exact server `SUPABASE_URL`.
- `EXECUTE_APPLE_GRANT_CLIENT_ID` and `EXECUTE_APPLE_GRANT_CLIENT_SECRET`
  for the single registered Apple service used by the project's OAuth flow.
- `EXECUTE_APPLE_GRANT_KEY_ID` naming the active key and
  `EXECUTE_APPLE_GRANT_KEYS`, a JSON object whose values are 32-byte random
  keys encoded as hexadecimal. Retain previous key versions while grants
  encrypted with them remain. Rotation keeps the old ID and value available
  and changes the active ID for new records.
- Build the native QA app with `APPLE_GRANT_PROJECT_URL` set to the same
  public origin. The build default leaves custody disabled.

The server route must be verified before enabling the native flag. The
isolated acceptance needs one clean Apple authorization, one account with
no available grant, a same-owner retry after a forced cleanup failure, and
an independently observed successful revocation with the unrelated owner
preserved. Capture closure blocks fresh vault writes. Verify concurrent
re-authorization through the released client and any older OAuth entry point
before production cutover. The legacy deletion endpoint must be blocked or
replaced by the compatible guarded route before enabling production capture.
The pending-grant Auth foreign key prevents discarding captured credentials.

Disable capture and withdraw the staged deletion endpoint before rollback.
`reverse-apple-grant-custody.sql` refuses to drop retained grants or active
closure records. Plan a separately reviewed handoff while the older keys
are available if either table has records.

- [Apple's token verification guidance](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)
- [Apple's token revocation response contract](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)
