import { equal } from "node:assert/strict";
import Stripe from "stripe";
import { createStripeHandler } from "./reconcile.ts";

// Real local HMAC/signature verification with the deployed entrypoint's SDK
// boundary. This is not evidence of live Stripe delivery or webhook setup.
const secret = "whsec_isolated_test_fixture";
const body = JSON.stringify({
  id: "evt_signature_fixture",
  type: "fixture.unhandled",
  data: { object: { id: "sub_fixture" } },
});
const provider = Stripe.createSubtleCryptoProvider();
function signatureFixture() {
  let externalCalls = 0;
  const handler = createStripeHandler({
    webhookSecret: secret,
    fetch: (() => {
      externalCalls++;
      return Promise.reject(new Error("Provider lookup must not run"));
    }) as typeof fetch,
    verifyEvent: (payload, signature, webhookSecret) =>
      Stripe.webhooks.constructEventAsync(
        payload,
        signature,
        webhookSecret,
        undefined,
        provider,
      ),
    read: () => {
      externalCalls++;
      return Promise.reject(new Error("Database read must not run"));
    },
    apply: () => {
      externalCalls++;
      return Promise.reject(new Error("Database write must not run"));
    },
  });
  const request = (payload: string, signature: string | null) =>
    new Request("https://fixture.invalid/stripe", {
      method: "POST",
      headers: signature ? { "stripe-signature": signature } : {},
      body: payload,
    });
  return { handler, request, externalCalls: () => externalCalls };
}

async function signedHeader(
  payload: string,
  signingSecret: string,
  timestamp = Math.floor(Date.now() / 1000),
) {
  const signature = await provider.computeHMACSignatureAsync(
    `${timestamp}.${payload}`,
    signingSecret,
  );
  return Stripe.webhooks.generateTestHeaderString({
    payload,
    secret: signingSecret,
    timestamp,
    signature,
  });
}

Deno.test("real Stripe SDK accepts authentic raw-body signature before safely skipping unsupported event", async () => {
  const f = signatureFixture();
  const header = await signedHeader(body, secret);
  const response = await f.handler(f.request(body, header));
  equal(response.status, 200);
  equal((await response.json()).skipped, "fixture.unhandled");
  equal(f.externalCalls(), 0);
});

Deno.test("real Stripe SDK rejects tampered and reserialized raw body before any provider/database work", async () => {
  const header = await signedHeader(body, secret);
  for (
    const payload of [
      body.replace("evt_signature_fixture", "evt_tampered"),
      JSON.stringify(JSON.parse(body), null, 2),
    ]
  ) {
    const f = signatureFixture();
    equal((await f.handler(f.request(payload, header))).status, 400);
    equal(f.externalCalls(), 0);
  }
});

Deno.test("real Stripe SDK rejects invalid, stale and missing signature before external work", async () => {
  const invalid = await signedHeader(body, "wrong_secret");
  const stale = await signedHeader(
    body,
    secret,
    Math.floor(Date.now() / 1000) - 600,
  );
  for (const header of [invalid, stale, null]) {
    const f = signatureFixture();
    equal((await f.handler(f.request(body, header))).status, 400);
    equal(f.externalCalls(), 0);
  }
});
