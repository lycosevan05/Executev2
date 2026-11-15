# Execute

Execute is now wired to Supabase for auth, data, storage, realtime updates, and Edge Functions. AI calls are routed through a Supabase Edge Function that uses `OPENAI_API_KEY` server-side.

## Native migration completion — 2026-11-15

The [authoritative completion checklist](docs/native-parity-audit.md) fixes the retained native scope at **45 required workflows: 16 functionally accepted, 29 open, plus 9 separate release gates**. Workflow counts are distinct from fixture-test counts; do not use rough migration percentages. It replaces old missing-destination/platform-blocked audit summaries and separates implementation, fixtures, live simulator/provider/database and physical acceptance. Use standalone `ios-native`.

The canonical chronological progress record is the [Execute Document](https://docs.google.com/spreadsheets/d/1_OzvTKdgPQoWczXRffeqoZuHOj5Nh2tlQ1xYuJYecLY/edit), maintained by a separate agent from verified milestone evidence. Update the checklist, checkpoint and evidence after coherent milestones. Report accepted workflows, remaining rows, critical path and next concrete action.

The [billing integration handoff](docs/reports/2026-11-08-billing-review.md) and dated README notes are supporting historical evidence, not current scope. The former StoreKit Code3/platform blocker was resolved by the November9 four-case local fixture pass; alternate-device registration/profile access is the current physical blocker. No unchanged retries or repeated agreement requests.

Next authorized work: session-safe retained Profile nutrition/workout/coaching editors and their context. Do not branch into optional cookbook replacement or new composition/storage features while required rows remain open. Existing Developer changes and synthetic activity must be preserved. General setup/deployment commands below are not authorization for new deployments, billing mutations, account deletion, pushing, merging or distribution.

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
