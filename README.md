# Execute

Execute is now wired to Supabase for auth, data, storage, realtime updates, and Edge Functions. AI calls are routed through a Supabase Edge Function that uses `OPENAI_API_KEY` server-side.

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
