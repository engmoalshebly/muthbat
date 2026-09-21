import { serviceClient } from "./supabase.ts";
export { requestAddress } from "./request-address.ts";

export class RateLimitExceededError extends Error {
  constructor(public readonly retryAfterSeconds = 60) {
    super("rate_limit_exceeded");
    this.name = "RateLimitExceededError";
  }
}

type RateLimitRule = {
  scope: string;
  subjectKey: string;
  maxHits: number;
  windowSeconds: number;
};

async function stableKey(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function enforceRateLimits(rules: RateLimitRule[]): Promise<void> {
  const admin = serviceClient();
  for (const rule of rules) {
    const { error } = await admin.rpc("service_consume_rate_limit", {
      p_scope: rule.scope,
      p_subject_key: await stableKey(rule.subjectKey),
      p_max_hits: rule.maxHits,
      p_window_seconds: rule.windowSeconds,
    });
    if (error) {
      const message = error.message?.toLowerCase() ?? "";
      if (error.code === "42901" || message.includes("rate limit exceeded")) {
        throw new RateLimitExceededError(rule.windowSeconds);
      }
      throw error;
    }
  }
}
