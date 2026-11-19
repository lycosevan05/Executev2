/** The guarded writer and deletion use the same durable dispatch identity. */
export interface CheckoutOwner {
  id: string;
  email?: string | null;
}

interface Dispatcher {
  dispatch_id: string;
  stripe_session_id: string | null;
}

interface LocalCheckoutLedger {
  begin(owner: CheckoutOwner): Promise<string | undefined>;
  acknowledge(
    owner: CheckoutOwner,
    dispatch: string,
    session: string,
  ): Promise<boolean>;
  close(owner: CheckoutOwner): Promise<Dispatcher[]>;
  finish(owner: CheckoutOwner, rows: Dispatcher[]): Promise<void>;
}

export interface CheckoutDrainPlan {
  subscriptionIds: readonly string[];
  finish(): Promise<void>;
}

export interface StripeCheckoutSession {
  id: string;
  mode: string;
  status: string | null;
  payment_status: string;
  subscription: string | { id: string } | null;
  metadata: Record<string, string> | null;
  after_expiration?: { recovery?: { enabled: boolean } | null } | null;
  recovered_from?: string | null;
  url?: string | null;
}

interface StripeCheckoutProvider {
  retrieve(id: string): Promise<StripeCheckoutSession>;
  expire(id: string): Promise<StripeCheckoutSession>;
}

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const sessionIdentifier = /^cs_(?:test|live)_[A-Za-z0-9]{1,240}$/;
const subscriptionIdentifier = /^sub_[A-Za-z0-9_]{1,250}$/;

type RpcResult = { data: unknown; error: { code?: string } | null };

export function createStripeCheckoutLedger(
  rpc: (name: string, args: Record<string, unknown>) => PromiseLike<RpcResult>,
): LocalCheckoutLedger {
  const identity = ({ id, email }: CheckoutOwner) => ({
    p_owner_id: id,
    p_email: email ?? null,
  });
  return {
    async begin(owner) {
      const { data, error } = await rpc(
        "begin_guarded_stripe_checkout",
        identity(owner),
      );
      if (error?.code === "55000") return;
      if (error || typeof data !== "string" || !uuid.test(data)) {
        throw new Error("Stripe checkout registration was not confirmed.");
      }
      return data;
    },
    async acknowledge(owner, dispatch, session) {
      const { data, error } = await rpc("acknowledge_guarded_stripe_checkout", {
        ...identity(owner),
        p_dispatch_id: dispatch,
        p_session_id: session,
      });
      if (error || typeof data !== "boolean") {
        throw new Error("Stripe checkout acknowledgement was not confirmed.");
      }
      return data;
    },
    async close(owner) {
      const { data, error } = await rpc(
        "close_and_list_guarded_stripe_checkouts",
        identity(owner),
      );
      if (error || !Array.isArray(data) || data.length > 100) {
        throw new Error("Stripe checkout admission closure was not confirmed.");
      }
      const dispatches: Dispatcher[] = [];
      const seenDispatches = new Set<string>();
      const seenSessions = new Set<string>();
      for (const value of data) {
        const { dispatch_id, stripe_session_id } = value ?? {};
        if (
          typeof dispatch_id !== "string" || !uuid.test(dispatch_id) ||
          seenDispatches.has(dispatch_id) ||
          (stripe_session_id !== null &&
            (typeof stripe_session_id !== "string" ||
              !sessionIdentifier.test(stripe_session_id) ||
              seenSessions.has(stripe_session_id)))
        ) {
          throw new Error("Stripe checkout inventory could not be verified.");
        }
        seenDispatches.add(dispatch_id);
        if (stripe_session_id) seenSessions.add(stripe_session_id);
        dispatches.push({ dispatch_id, stripe_session_id });
      }
      return dispatches;
    },
    async finish(owner, rows) {
      const { data, error } = await rpc(
        "finish_guarded_stripe_checkout_drain",
        {
          ...identity(owner),
          p_rows: rows,
        },
      );
      if (error || data !== true) {
        throw new Error("Stripe checkout drain completion was not confirmed.");
      }
    },
  };
}

export function exactCheckoutMetadata(owner: CheckoutOwner, dispatch: string) {
  if (!uuid.test(owner.id) || !owner.email || !uuid.test(dispatch)) {
    throw new Error("Stripe checkout identity could not be verified.");
  }
  return {
    user_id: owner.email,
    execute_owner_uuid: owner.id,
    execute_checkout_dispatch: dispatch,
  };
}

function verifySession(
  session: StripeCheckoutSession,
  sessionId: string,
  owner: CheckoutOwner,
  dispatch: string,
) {
  const expected = exactCheckoutMetadata(owner, dispatch);
  const recovery = session.after_expiration?.recovery;
  if (
    !sessionIdentifier.test(sessionId) || session.id !== sessionId ||
    session.mode !== "subscription" ||
    session.recovered_from != null ||
    (recovery != null && recovery.enabled !== false) ||
    Object.entries(expected).some(([key, expectedValue]) =>
      session.metadata?.[key] !== expectedValue
    )
  ) {
    throw new Error("Stripe checkout did not match the verified dispatch.");
  }
}

export async function acknowledgeExactCheckout(
  ledger: Pick<LocalCheckoutLedger, "acknowledge">,
  owner: CheckoutOwner,
  dispatch: string,
  session: StripeCheckoutSession,
) {
  verifySession(session, session.id, owner, dispatch);
  return await ledger.acknowledge(owner, dispatch, session.id);
}

function settledSubscription(
  session: StripeCheckoutSession,
): string | undefined {
  if (session.status === "expired") {
    if (session.subscription != null) {
      throw new Error("Expired Stripe checkout has a subscription.");
    }
    return;
  }
  if (
    session.status === "complete" &&
    (session.payment_status === "paid" ||
      session.payment_status === "no_payment_required")
  ) {
    const subscription = typeof session.subscription === "string"
      ? session.subscription
      : session.subscription?.id;
    if (subscription && subscriptionIdentifier.test(subscription)) {
      return subscription;
    }
  }
  throw new Error("Stripe checkout settlement is not verified.");
}

/** Close admission first. A pending provider call, unbound receipt, or unpaid
 * complete session stays reserved until independently reconciled. */
export async function drainGuardedStripeCheckouts(
  ledger: Pick<LocalCheckoutLedger, "close" | "finish">,
  stripe: () => StripeCheckoutProvider,
  owner: CheckoutOwner,
): Promise<CheckoutDrainPlan> {
  const rows = await ledger.close(owner);
  if (rows.some((row) => row.stripe_session_id === null)) {
    throw new Error(
      "Stripe checkout cleanup is waiting for a verified dispatch.",
    );
  }
  const subscriptions = new Set<string>();
  const open: { id: string; dispatch: string }[] = [];
  for (const { dispatch_id, stripe_session_id } of rows) {
    const id = stripe_session_id!;
    const session = await stripe().retrieve(id);
    verifySession(session, id, owner, dispatch_id);
    if (session.status === "open" && session.subscription == null) {
      open.push({ id, dispatch: dispatch_id });
      continue;
    }
    const subscription = settledSubscription(session);
    if (subscription) subscriptions.add(subscription);
  }
  for (const { id, dispatch } of open) {
    // Stripe can race completion against expiration, or the first reply may
    // have timed out after it committed. Read this exact session once more.
    const terminal = await stripe().expire(id).catch(() =>
      stripe().retrieve(id)
    );
    verifySession(terminal, id, owner, dispatch);
    const subscription = settledSubscription(terminal);
    if (subscription) subscriptions.add(subscription);
  }
  return {
    subscriptionIds: [...subscriptions],
    finish: () => ledger.finish(owner, rows),
  };
}
