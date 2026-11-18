# Isolated native session acceptance (W04)

This fixture runs the existing Swift Auth, session, owner-scoped repository, cache, router and billing boundaries against disposable local Supabase Auth and PostgREST. The test host uses the app's pinned SDK. RevenueCat is a free fixture, and the paid A account is seeded only in the local subscription table. The tests require explicit opt-in and skip during ordinary XCTest runs.

## Start the dedicated stack

Use the Supabase CLI v2 (`supabase-go` 2.101.0 in the migration environment), Python 3.11 or later, a running local Docker runtime, Xcode and a dedicated fixture simulator. The first stack start can pull images. Check that no local fixture named `execute-w04-e59` is running and that host ports 55420 through 55422 are free. Use a fresh temporary project outside the repository and keep stdout private because Supabase prints test credentials.

```sh
repo=$(pwd)  # Repository root
fixture=$(mktemp -d /private/tmp/execute-w04.XXXXXX)
mkdir "$fixture/supabase"
cp "$repo/supabase/tests/native-auth/config.toml" "$fixture/supabase/config.toml"
cp -R "$repo/supabase/migrations" "$fixture/supabase/migrations"
docker network create --driver bridge \
  --opt com.docker.network.bridge.host_binding_ipv4=127.0.0.1 execute-w04-e59-loopback
supabase-go start --workdir "$fixture" --network-id execute-w04-e59-loopback \
  -x realtime,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor \
  > "$fixture/start.log" 2>&1
docker port supabase_kong_execute-w04-e59
docker port supabase_db_execute-w04-e59
```

The stack uses Auth, the API gateway, PostgREST, Postgres and Storage. The original migration chain needs the Storage schema. Treat the bridge option as a request. Docker Desktop can ignore it when the CLI explicitly publishes ports. Check that the gateway and database show only `127.0.0.1` bindings. Stop the fixture if any other host address appears. The runner independently verifies bindings before reading credentials. Never link the temporary project or apply the short session policy to a shared or hosted project. No email leaves the stack. The test generates OTPs for its confirmed synthetic accounts through the local admin endpoint.

On Docker Desktop, a verified recovery is to stop only the synthetic Kong and DB containers, then recreate them with `-p 127.0.0.1:55421:8000` and `-p 127.0.0.1:55422:5432` respectively. Preserve their fixture container names, network aliases, local configuration and named DB volume. Keep inspection exports private because they can contain fixture credentials. Verify the new published addresses and stack health before sending test traffic. If those conditions cannot be met, stop the disposable stack.

## Run the tests

For a backend check without Xcode, run
`python3 supabase/tests/native-auth/backend-smoke.py --stack-dir "$fixture"`.
It tests terminal expiry and fresh same-owner email sign-in before verifying two
independent authenticated PostgREST reads. It creates only synthetic fixture
accounts and records, and prints the outcomes without credentials or row data.

Build from a dedicated debug checkout with no `Local.xcconfig` or provider credentials. Use its generated `ExecuteNative` `.xctestrun` under the derived directory's `Build/Products`. Supply the fixture simulator UUID, never a physical or preserved QA device. The runner injects credentials into a mode-0600 temporary copy of that plan and removes it when Xcode exits. Keep Xcode logs and any result bundle private.

```sh
xcodebuild -project ios-native/ExecuteNative.xcodeproj -scheme ExecuteNative \
  -configuration Debug -destination "platform=iOS Simulator,id=$fixture_simulator_id" \
  -derivedDataPath "$fixture/derived" \
  -only-testing:ExecuteNativeTests/IsolatedNativeAuthTests build-for-testing

python3 supabase/tests/native-auth/run.py \
  --stack-dir "$fixture" \
  --xctestrun "$fixture_xctestrun" \
  --simulator-id "$fixture_simulator_id" \
  --result-bundle "$fixture/W04.xcresult"
```

If simulator ATS refuses loopback HTTP (`NSURLErrorDomain -1022`), add an individual `127.0.0.1` `NSExceptionDomains` exception with `NSExceptionAllowsInsecureHTTPLoads` in a temporary copy of the Debug test host's Info.plist. Build only from that disposable checkout and discard the exception before using it for any other build. Leave the tracked app configuration and Release ATS settings intact. [Apple ATS exception domains](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)

## Interpret the results

- **Terminal server expiry.** The Auth server has a real 15-second maximum session lifetime. The test waits past it and sets only the test storage's `expiresAt` to force the first refresh. The server-issued credentials remain intact. Native startup must land on signed out, clear the saved session, stay signed out on another start and recover through a fresh OTP for the same owner UUID. This covers the elapsed server policy and native behavior on refresh. Normal app acceptance still requires natural JWT expiry using real durable storage. [Supabase session lifetimes and refresh](https://supabase.com/docs/guides/auth/sessions) · [Local session configuration](https://supabase.com/docs/guides/local-development/cli/config#authsessionstimebox)
- **In-flight account switch.** A writes a goal, receives backend Premium and opens a route. The test holds A's successful real PostgREST result at the repository boundary before returning it to the captured account adapter. The app signs out A and signs in B, verifies clean navigation and cache, then creates B's own goal. Releasing A must cancel the previous result while B remains signed in with its own route, cache and free access. B's real owner-scoped read must contain only B's test record. This exercises a delayed feature result. The pinned-SDK stale Auth refresh test separately covers the case where a prior Auth response replaces SDK storage and the app closes its session.
- A skipped method is no evidence. Record which service images, source revision and simulator ran, whether each method passed, and any remaining physical, signed or hosted test conditions. Never include fixture tokens, OTPs, keys or complete auth rows in a progress record.

The November 17 local provider smoke used the official Auth service and all six repository migrations. An initial email OTP issued a session for the synthetic owner. After the 15-second time box, refresh returned `session_expired`, and a fresh email OTP opened a new session for the same owner. This records server behavior independently of the native XCTest results.

Both synthetic accounts also received exactly their own goal through authenticated
PostgREST. The native test target built from a local copy of E59. The simulator
test host exited before either XCTest method ran. A successful compilation
establishes neither terminal-expiry UI acceptance nor native in-flight isolation.

Stop and purge only this disposable fixture after the tests. This removes its test users and synthetic database records. Keep any selected sanitized evidence separately.

```sh
supabase-go stop --workdir "$fixture" --project-id execute-w04-e59 --no-backup
docker network rm execute-w04-e59-loopback
```
