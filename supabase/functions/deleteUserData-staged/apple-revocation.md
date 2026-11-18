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
project-and-account allowlist still applies. Set `EXECUTE_STAGED_APPLE_GRANT`
only in that runtime's secret store and only from a verified Apple exchange for
that exact account. The JSON fields are `ownerId`, `subject`, `clientId`,
`clientSecret`, and `refreshToken`. Use the Apple OAuth client ID that issued
the grant. Remove the one-off secret at the end of the experiment, including
after a failed or aborted experiment. Client requests supply no Apple token,
account identifier, or destination URL. Logs and deletion receipts contain no
credential material.

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
handling with a real disposable Apple identity. Staging fixtures exercise the
request and retry contract using a mocked provider. Production acquisition and
live Apple revocation acceptance remain open.
