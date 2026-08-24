export function corsHeaders(request: Request): HeadersInit {
  const allowedOrigins = (Deno.env.get("ALLOWED_ORIGIN") ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  const requestOrigin = request.headers.get("origin") ?? "";
  // Fail closed: if no ALLOWED_ORIGIN is configured or the request origin
  // is not in the list, the Access-Control-Allow-Origin header is empty.
  // Browsers will reject the response — no wildcard '*' fallback.
  const origin = allowedOrigins.includes(requestOrigin)
    ? requestOrigin
    : "";

  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-worker-secret",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Vary": "Origin",
  };
}

export function optionsResponse(request: Request): Response | null {
  if (request.method !== "OPTIONS") return null;
  return new Response("ok", { headers: corsHeaders(request) });
}
