import type { DeletionBilling, DeletionUser } from "./deletion.ts";
export interface DeletionStripe {
  subscriptions: {
    retrieve(
      id: string,
    ): Promise<{ status: string; metadata: Record<string, string> }>;
    cancel(id: string): Promise<unknown>;
  };
}
export function createDeletionBilling(
  getStripe: () => DeletionStripe,
): DeletionBilling {
  const noCancellationNeeded = new Set<string>();
  const verified = new Set<string>();
  function missing(error: unknown) {
    return (error as { code?: string })?.code === "resource_missing";
  }
  return {
    async verifyOwner(id: string, user: DeletionUser) {
      let subscription;
      try {
        subscription = await getStripe().subscriptions.retrieve(id);
      } catch (error) {
        if (missing(error)) {
          verified.add(id);
          noCancellationNeeded.add(id);
          return;
        }
        throw new Error(
          "Subscription ownership could not be verified; no account data deleted.",
        );
      }
      // Checkout sets metadata.user_id to the authenticated email (or UUID).
      // Missing/mismatched legacy metadata needs operator reconciliation, never blind cancellation.
      const owner = subscription.metadata.user_id;
      if (owner !== user.id && (!user.email || owner !== user.email)) {
        throw new Error(
          "Subscription ownership does not match; cleanup stopped.",
        );
      }
      verified.add(id);
      if (subscription.status === "canceled") noCancellationNeeded.add(id);
    },
    async cancel(id) {
      if (!verified.has(id)) {
        throw new Error("Subscription cancellation was not verified.");
      }
      if (noCancellationNeeded.has(id)) return;
      try {
        await getStripe().subscriptions.cancel(id);
      } catch (error) {
        if (missing(error)) return;
        throw new Error(
          "Subscription cancellation failed; account data retained for retry.",
        );
      }
    },
  };
}
