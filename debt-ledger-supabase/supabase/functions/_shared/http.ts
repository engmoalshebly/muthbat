import { corsHeaders } from "./cors.ts";

export function json(request: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(request), "Content-Type": "application/json; charset=utf-8" },
  });
}

export function errorResponse(
  request: Request,
  status: number,
  code: string,
  message: string,
  extraHeaders: HeadersInit = {},
): Response {
  const response = json(request, { error: { code, message } }, status);
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(extraHeaders)) headers.set(key, String(value));
  return new Response(response.body, { status, headers });
}

export function rateLimitResponse(request: Request, retryAfterSeconds: number): Response {
  return errorResponse(
    request,
    429,
    "rate_limited",
    "Too many requests. Please try again later.",
    { "Retry-After": String(retryAfterSeconds) },
  );
}

export async function readJson<T>(request: Request): Promise<T> {
  try {
    return await request.json() as T;
  } catch {
    throw new Error("invalid_json");
  }
}

export function requirePost(request: Request): Response | null {
  return request.method === "POST" ? null : errorResponse(request, 405, "method_not_allowed", "POST is required");
}
