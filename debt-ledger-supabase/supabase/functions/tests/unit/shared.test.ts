import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { corsHeaders } from "../../_shared/cors.ts";
import { requestAddress } from "../../_shared/request-address.ts";

Deno.test("cors fails closed when the request origin is not allowed", () => {
  const previous = Deno.env.get("ALLOWED_ORIGIN");
  Deno.env.set("ALLOWED_ORIGIN", "https://app.example.com");
  try {
    const headers = new Headers(corsHeaders(new Request("https://functions.example.com", {
      headers: { origin: "https://evil.example.com" },
    })));
    assertEquals(headers.get("Access-Control-Allow-Origin"), "");
  } finally {
    if (previous === undefined) Deno.env.delete("ALLOWED_ORIGIN");
    else Deno.env.set("ALLOWED_ORIGIN", previous);
  }
});

Deno.test("requestAddress prefers the edge-provided address", () => {
  const request = new Request("https://functions.example.com", {
    headers: {
      "cf-connecting-ip": "203.0.113.10",
      "x-real-ip": "198.51.100.10",
      "x-forwarded-for": "192.0.2.10",
    },
  });
  assertEquals(requestAddress(request), "203.0.113.10");
});
