# Native screen loading acceptance

## Build 3 baseline

The connected iPhone reported bundle `com.executelabs.execute.native-dev` version
1.0 build 3 through CoreDevice. The owner chose to continue without a baseline
video. No tap-to-frame or tap-to-content timing samples were collected.

At 9:58 p.m. Vancouver time on November 19, the Workout screenshot reported that
the database could not be queried for its schema cache. The observed copy is
consistent with PostgREST's connection or schema-cache error family. The read-only
Executev2 Logs Explorer query returned no rows in the incident window. The
exact backend error code, request duration, and whether other routes were
affected are unverified.

## Route audit

| Route | First render and refresh |
| --- | --- |
| Home | Draw the header and navigation immediately. Reopen with the last verified dashboard and retain it on read failure. Automatic goal tracking follows the first verified dashboard. |
| Train | Restore the verified active plan and workout summaries by account. Completed history runs independently. Local exercise library navigation can render before the plan read. |
| Track | Restore the verified account and date snapshot. Wait for authoritative data before enabling mutations. Fetch full history in Tracking History and check any pending receipt for its exact date. |
| Plan and onboarding | Restore the verified active plan on the Plan tab. Confirm absence only after a successful active-plan response. Load setup profiles when setup opens. |
| Workout and meal detail | Restore the verified saved day by account, type and date. Filter opening reads to the active plan and selected date. Revalidate write decisions on Generate and Save. |
| Nutrition, Food Log and Water | Restore saved totals by account and date. Load intake and optional plan data independently. Nutrition and Water share identical in-flight DailyLog reads. Water still validates duplicates and pending receipts before accepting a change. |
| My Week, Goals, Progress and Insights | Navigation draws immediately. Verified content still depends on historical reads, reconciliation or analysis. Common entity reads have a per-request deadline. Dedicated saved snapshots and route-level timings remain open for these destinations. |
| Recovery, Profile and workout session | Existing session and write checks remain in force. Entity reads use the common deadline where applicable. Per-route cached reopening and device timing remain open. |
| Billing, Privacy and Terms | Billing uses its existing provider workflow. Legal views use bundled content. Device timing was not collected. |

The shared read key includes the authenticated session, entity, filters, sort and
page. Cancellation or a changed session prevents returning the old result to
the caller. Authenticated writes invalidate overlapping reads for the affected
table. Native REST entity reads use a six-second per-request deadline and no
automatic transport retry. This deadline applies to each request, so scanning
several historical pages still needs separate optimization.

## Physical-device acceptance

Report both first-visit and repeat-visit samples for the same account, network
and phone, on the baseline and candidate builds. Measure from the visible tap
to the first screen frame and to the first frame containing useful data. Report
the sample counts and p95 for each route. The cached targets are p95 under
150 ms for a screen frame and under 300 ms for meaningful saved content.
Screens with no saved data must show available controls and localized unknown
states during slow, offline or failed reads. Simulator fixture durations are
regression evidence, not iPhone performance measurements.
