# Execute

Execute is now wired to Supabase for auth, data, storage, realtime updates, and Edge Functions. AI calls are routed through a Supabase Edge Function that uses `OPENAI_API_KEY` server-side.

## Native migration progress — 2026-11-08

The canonical progress record is the [Execute Document in Google Drive](https://docs.google.com/spreadsheets/d/1_OzvTKdgPQoWczXRffeqoZuHOj5Nh2tlQ1xYuJYecLY/edit). Write progress there as work proceeds: update it after each meaningful milestone and leave a short resumable checkpoint before any handoff. Use a separate agent to maintain these updates, giving it verified results and evidence from the implementation work.

Each update must include the result, relevant commits/PRs and environments, verification evidence, remaining dependencies or blockers, and the next action. Distinguish implementation complete, locally tested, provider verified, and device verified; do not present historical handoff claims as newly verified results. Keep credentials and secret values out of all progress records.

The [native billing and integration handoff](docs/reports/2026-11-08-billing-review.md) remains supporting repository detail. Keep it consistent with milestone updates; it does not replace writing progress to the Execute Document in Google Drive.

- Billing reconciliation is implemented and locally verified (`51332a8`).
- The two webhooks are deployed to a **separate integration project**; production is unchanged. RevenueCat test transport/authentication passes. Stripe endpoint and real-provider acceptance checks are in progress.
- The focused Recovery retry fix is saved separately (`c301f6c`), with model regressions passing; Recovery PR #2 remains draft and unmerged.
- Native end-to-end acceptance remains open while Xcode platform recognition is blocked.

Use the handoff's scoped deployment procedure for migration work. The general setup commands below are not authorization to push every migration to an existing backend.

## Local Setup

Create `.env.local`:

```bash
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-supabase-anon-key
VITE_SUPABASE_UPLOAD_BUCKET=uploads
```

Use the project API URL for `VITE_SUPABASE_URL`, not the Supabase dashboard URL. It should look like `https://your-project-ref.supabase.co`.

Set these Supabase Edge Function secrets:

```bash
supabase secrets set OPENAI_API_KEY=sk-...
supabase secrets set OPENAI_MODEL=gpt-4.1-mini
supabase secrets set SERVICE_ROLE_KEY=your-service-role-key
```

Do not add custom secrets that start with `SUPABASE_`. Supabase reserves that prefix and automatically provides built-in values like `SUPABASE_URL` and `SUPABASE_ANON_KEY` to Edge Functions.

## Supabase

Apply the database/storage/realtime schema:

```bash
supabase link --project-ref your-project-ref
supabase db push
```

Deploy functions:

```bash
supabase functions deploy invoke-llm
supabase functions deploy deleteUserData
```

## Development

```bash
npm install
npm run dev
```

`npm run dev` keeps running while the app is open. Leave that terminal window alone, then open the local URL Vite prints, usually `http://localhost:5173/`. Press `Ctrl+C` in that terminal when you want to stop the dev server.
