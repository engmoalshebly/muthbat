function firstForwardedValue(value: string | null): string | null {
  const first = value?.split(",")[0]?.trim();
  return first || null;
}

/** Resolve the address supplied by the trusted edge proxy. */
export function requestAddress(request: Request): string {
  return (
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-real-ip") ??
    firstForwardedValue(request.headers.get("x-forwarded-for")) ??
    "unknown"
  );
}
