// deno-lint-ignore-file require-await
import { deepEqual, equal, rejects } from "node:assert/strict";
import { createDeletionBilling } from "../deleteUserData/billing.ts";
import {
  deleteAccount,
  type DeletionStore,
} from "../deleteUserData/deletion.ts";
import {
  acknowledgeExactCheckout,
  createStripeCheckoutLedger,
  drainGuardedStripeCheckouts,
  exactCheckoutMetadata,
  type StripeCheckoutSession,
} from "./stripeCheckoutGuard.ts";

const owner = {
  id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  email: "qa@example.invalid",
};
const first = "01234567-1111-1111-1111-111111111111";
const second = "01234567-2222-2222-2222-222222222222";
const cs1 = "cs_test_first";
const cs2 = "cs_test_second";

function session(
  id = cs1,
  dispatch = first,
  data: Partial<StripeCheckoutSession> = {},
): StripeCheckoutSession {
  return {
    id,
    mode: "subscription",
    status: "open",
    payment_status: "unpaid",
    subscription: null,
    metadata: exactCheckoutMetadata(owner, dispatch),
    ...data,
  };
}

function fixture(rows = [{ dispatch_id: first, stripe_session_id: cs1 }] as {
  dispatch_id: string;
  stripe_session_id: string | null;
}[]) {
  const calls: string[] = [];
  const ledger = createStripeCheckoutLedger(async (name, args) => {
    calls.push(name);
    equal(args.p_owner_id, owner.id);
    equal(args.p_email, owner.email);
    if (name === "close_and_list_guarded_stripe_checkouts") {
      return { data: rows, error: null };
    }
    if (name === "finish_guarded_stripe_checkout_drain") {
      deepEqual(args.p_rows, rows);
    }
    return {
      data: name === "finish_guarded_stripe_checkout_drain" ? true : false,
      error: null,
    };
  });
  return { calls, ledger };
}

Deno.test("checkout receipt uses the exact owner and dispatch and withholds the URL on concurrent closure", async () => {
  const { calls, ledger } = fixture();
  equal(await acknowledgeExactCheckout(ledger, owner, first, session()), false);
  await rejects(
    acknowledgeExactCheckout(ledger, owner, second, session()),
    /verified dispatch/,
  );
  deepEqual(calls, ["acknowledge_guarded_stripe_checkout"]);
});

Deno.test("checkout registration fails closed on ambiguous SQL results", async () => {
  const closed = createStripeCheckoutLedger(async () => ({
    data: null,
    error: { code: "55000" },
  }));
  const unresolved = createStripeCheckoutLedger(async () => ({
    data: true,
    error: null,
  }));
  equal(await closed.begin(owner), undefined);
  await rejects(unresolved.begin(owner), /registration/);
});

Deno.test("unknown dispatch stops all provider operations", async () => {
  const { calls, ledger } = fixture([
    { dispatch_id: first, stripe_session_id: cs1 },
    { dispatch_id: second, stripe_session_id: null },
  ]);
  await rejects(
    drainGuardedStripeCheckouts(ledger, () => {
      throw new Error("Provider must remain untouched");
    }, owner),
    /waiting for a verified dispatch/,
  );
  deepEqual(calls, ["close_and_list_guarded_stripe_checkouts"]);
});

Deno.test("foreign, recoverable and unpaid checkout is rejected before any sibling expiration", async () => {
  for (
    const malformed of [
      { metadata: exactCheckoutMetadata(owner, first) },
      { after_expiration: { recovery: { enabled: true } } },
      {
        status: "complete",
        payment_status: "unpaid",
        subscription: "sub_pending",
      },
    ]
  ) {
    const { calls, ledger } = fixture([
      { dispatch_id: first, stripe_session_id: cs1 },
      { dispatch_id: second, stripe_session_id: cs2 },
    ]);
    await rejects(
      drainGuardedStripeCheckouts(ledger, () => ({
        retrieve: async (id) =>
          id === cs1 ? session() : session(cs2, second, malformed),
        expire: async () => {
          calls.push("expire");
          throw new Error("Unexpected provider expiry");
        },
      }), owner),
      /verified dispatch|settlement is not verified/,
    );
    deepEqual(calls, ["close_and_list_guarded_stripe_checkouts"]);
  }
});

Deno.test("expiry racing completion inventories an exact settled subscription", async () => {
  const { calls, ledger } = fixture();
  let reads = 0;
  const plan = await drainGuardedStripeCheckouts(ledger, () => ({
    retrieve: async (id) => {
      calls.push("retrieve");
      equal(id, cs1);
      return ++reads === 1 ? session() : session(cs1, first, {
        status: "complete",
        payment_status: "paid",
        subscription: "sub_late",
      });
    },
    expire: async (id) => {
      calls.push("expire");
      equal(id, cs1);
      throw new Error("Already changed");
    },
  }), owner);
  deepEqual(plan.subscriptionIds, ["sub_late"]);
  deepEqual(calls, [
    "close_and_list_guarded_stripe_checkouts",
    "retrieve",
    "expire",
    "retrieve",
  ]);
  await plan.finish();
  equal(calls.at(-1), "finish_guarded_stripe_checkout_drain");
});

Deno.test("expire an exact open checkout without inventing a subscription", async () => {
  const { calls, ledger } = fixture();
  const plan = await drainGuardedStripeCheckouts(ledger, () => ({
    retrieve: async () => session(),
    expire: async () => {
      calls.push("expire");
      return session(cs1, first, { status: "expired" });
    },
  }), owner);
  deepEqual(plan.subscriptionIds, []);
  deepEqual(calls, ["close_and_list_guarded_stripe_checkouts", "expire"]);
});

function deletionStore(
  calls: string[],
  fence: () => Promise<void>,
): DeletionStore {
  return {
    prepareRows: async () => ({
      subscriptionIds: [],
      closeBillingProjection: fence,
      deleteRows: async () => {
        calls.push("rows");
        return 1;
      },
    }),
    listUploads: async () => [],
    removeUploads: async () => {},
    assertRowsAbsent: async () => {},
    deleteAuthentication: async () => {
      calls.push("Auth");
    },
  };
}

Deno.test("dispatched subscription missing from local rows is verified and canceled before ledger and Auth removal", async () => {
  const calls: string[] = [];
  const { ledger } = fixture();
  const billing = createDeletionBilling(() => ({
    subscriptions: {
      retrieve: async (id) => {
        equal(id, "sub_provider_only");
        calls.push("verify");
        const { user_id, execute_owner_uuid } = exactCheckoutMetadata(
          owner,
          first,
        );
        return { status: "active", metadata: { user_id, execute_owner_uuid } };
      },
      cancel: async (id) => {
        equal(id, "sub_provider_only");
        calls.push("cancel");
      },
    },
  }), { requireOwnerUUID: true });
  const plan = await drainGuardedStripeCheckouts(ledger, () => ({
    retrieve: async () =>
      session(cs1, first, {
        status: "complete",
        payment_status: "no_payment_required",
        subscription: "sub_provider_only",
      }),
    expire: async () => {
      throw new Error("Unexpected expiry");
    },
  }), owner);
  await deleteAccount(
    owner,
    ["goals"],
    deletionStore(calls, async () => {
      calls.push("fence");
    }),
    billing,
    undefined,
    undefined,
    async () => ({
      ...plan,
      async finish() {
        calls.push("finish");
        await plan.finish();
      },
    }),
  );
  deepEqual(calls, ["verify", "fence", "cancel", "rows", "finish", "Auth"]);
});

Deno.test("failed provider lookup or a changed billing row retains Auth and checkout dispatch", async () => {
  for (const missing of [true, false]) {
    const calls: string[] = [];
    const billing = createDeletionBilling(() => ({
      subscriptions: {
        retrieve: async () => {
          if (missing) throw { code: "resource_missing" };
          return {
            status: "active",
            metadata: {
              user_id: owner.email,
              execute_owner_uuid: owner.id,
            },
          };
        },
        cancel: async () => {
          calls.push("cancel");
        },
      },
    }), { requireOwnerUUID: true });
    await rejects(
      deleteAccount(
        owner,
        ["goals"],
        deletionStore(calls, async () => {
          throw new Error("Billing projection changed");
        }),
        billing,
        undefined,
        undefined,
        async () => ({
          subscriptionIds: ["sub_exact"],
          finish: async () => {
            calls.push("finish");
          },
        }),
      ),
      missing ? /ownership could not be verified/ : /projection changed/,
    );
    deepEqual(calls, []);
  }
});
