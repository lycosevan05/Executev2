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
