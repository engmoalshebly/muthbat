import { assertEquals, assertMatch } from "https://deno.land/std@0.224.0/assert/mod.ts";

const baseUrl = (Deno.env.get("FUNCTIONS_BASE_URL") ?? "http://127.0.0.1:55321/functions/v1").replace(/\/$/, "");
const headers = {
  "Content-Type": "application/json",
  ...(Deno.env.get("SUPABASE_ANON_KEY") ? { apikey: Deno.env.get("SUPABASE_ANON_KEY")! } : {}),
};

Deno.test("verify-statement rejects malformed verification codes over HTTP", async () => {
  const response = await fetch(`${baseUrl}/verify-statement`, {
    method: "POST",
    headers,
    body: JSON.stringify({ code: "bad" }),
  });
  assertEquals(response.status, 422);
  const body = await response.json();
  assertEquals(body.error.code, "invalid_code");
});

Deno.test("verify-statement returns a safe negative result for an unknown valid code", async () => {
  const response = await fetch(`${baseUrl}/verify-statement`, {
    method: "POST",
    headers,
    body: JSON.stringify({ code: "ST-UNKNOWN-000000" }),
  });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.valid, false);
  assertMatch(response.headers.get("vary") ?? "", /Origin/);
});

Deno.test("send-whatsapp-otp validates input before touching delivery services", async () => {
  const response = await fetch(`${baseUrl}/send-whatsapp-otp`, {
    method: "POST",
    headers,
    body: JSON.stringify({ phone: "not-a-phone" }),
  });
  assertEquals(response.status, 422);
  const body = await response.json();
  assertEquals(body.error.code, "invalid_phone");
});
