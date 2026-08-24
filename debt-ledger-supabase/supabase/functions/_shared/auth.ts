import type { User } from "npm:@supabase/supabase-js@2";
import { authenticatedClient } from "./supabase.ts";

export type AuthenticatedRequest = {
  user: User;
  accessToken: string;
  client: ReturnType<typeof authenticatedClient>;
};

export async function requireUser(request: Request): Promise<AuthenticatedRequest> {
  const authorization = request.headers.get("authorization") ?? "";
  const accessToken = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!accessToken) throw new Error("unauthorized");
  const client = authenticatedClient(accessToken);
  const { data, error } = await client.auth.getUser(accessToken);
  if (error || !data.user) throw new Error("unauthorized");
  return { user: data.user, accessToken, client };
}

export function requireWorkerSecret(request: Request): void {
  const expected = Deno.env.get("WORKER_SECRET");
  if (!expected || request.headers.get("x-worker-secret") !== expected) {
    throw new Error("unauthorized_worker");
  }
}
