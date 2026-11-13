# PDF input handler regression tests

Run from the repository root:

```sh
deno test --allow-read=supabase --allow-env=OPENAI_API_KEY,OPENAI_MODEL,PDF_SOURCE,FORCE_LLM_429 --import-map=supabase/tests/pdf-input-handler/import-map.json supabase/tests/pdf-input-handler/pdf_test.ts
```

The harness imports the real handler, replaces `getUser` with a fixture, and mocks provider fetch. It supplies a fake API key and needs no network or real credentials. Run in a fresh Deno process. These tests verify PDF forwarding, request compatibility, authentication rejection, malformed-input rejection and the 8 MB boundary; they do not prove live provider or production authentication behavior.

`PDF_SOURCE` can select another handler relative to `pdf_test.ts` for source comparison. The shared deployment approved on November 13 used the downloaded v6 baseline plus only the reviewed PDF validator/content change. The local handler retains its pre-existing retry implementation; this directory is not a deployment package.
