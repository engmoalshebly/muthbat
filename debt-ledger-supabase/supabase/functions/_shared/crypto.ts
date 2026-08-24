function toBytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function asArrayBuffer(value: Uint8Array): ArrayBuffer {
  return value.slice().buffer as ArrayBuffer;
}

function fromBase64(value: string): Uint8Array {
  const raw = atob(value);
  return Uint8Array.from(raw, (char) => char.charCodeAt(0));
}

function toBase64(value: Uint8Array): string {
  let output = "";
  for (const byte of value) output += String.fromCharCode(byte);
  return btoa(output);
}

function toHex(value: ArrayBuffer): string {
  return Array.from(new Uint8Array(value), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function keyValueForLocalRuntime(purpose: string): Promise<string | null> {
  const configured = Deno.env.get(purpose);
  // ملفات التطوير تُشحن بقيم إرشادية؛ لا تحاول فكها كـ Base64.
  // في الاستضافة الفعلية لا يعمل fallback المحلي وتبقى الأسرار الحقيقية إلزامية.
  if (configured && !configured.startsWith("CHANGE_ME")) return configured;

  // `supabase start` does not inject project .env values into the automatic
  // local Edge Runtime. Derive development-only keys from its private JWT
  // secret so local phone flows remain usable without embedding PII keys in
  // source. Hosted/staging runtimes must provide the explicit secrets above.
  const localSeed = Deno.env.get("SUPABASE_INTERNAL_JWT_SECRET")
    ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  // The automatic local runtime exposes the internal gateway URL as kong.
  // Hosted/staging URLs must use explicitly configured phone keys.
  const runtimeUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const isLocalRuntime = runtimeUrl === "http://kong:8000"
    || runtimeUrl.startsWith("http://127.0.0.1:")
    || runtimeUrl.startsWith("http://localhost:");
  if (!isLocalRuntime) return null;
  if (!localSeed) return null;
  const label = purpose === "PHONE_HMAC_KEY" ? "hmac" : "encryption";
  const digest = await crypto.subtle.digest(
    "SHA-256",
    asArrayBuffer(toBytes(`${localSeed}:muthbat:phone:${label}`)),
  );
  return toBase64(new Uint8Array(digest));
}

export function normalizeE164(input: string): string {
  const value = input.trim().replace(/[\s()\-]/g, "").replace(/^00/, "+");
  if (!/^\+[1-9]\d{7,14}$/.test(value)) throw new Error("invalid_phone");
  return value;
}

export async function phoneHash(phone: string): Promise<string> {
  const keyValue = await keyValueForLocalRuntime("PHONE_HMAC_KEY");
  if (!keyValue) throw new Error("missing_phone_hmac_key");
  const key = await crypto.subtle.importKey("raw", asArrayBuffer(fromBase64(keyValue)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toHex(await crypto.subtle.sign("HMAC", key, asArrayBuffer(toBytes(phone))));
}

export async function encryptPhone(phone: string): Promise<string> {
  const keyValue = await keyValueForLocalRuntime("PHONE_ENCRYPTION_KEY");
  if (!keyValue) throw new Error("missing_phone_encryption_key");
  const rawKey = fromBase64(keyValue);
  if (rawKey.byteLength !== 32) throw new Error("invalid_phone_encryption_key");
  const key = await crypto.subtle.importKey("raw", asArrayBuffer(rawKey), { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: asArrayBuffer(iv) }, key, asArrayBuffer(toBytes(phone))));
  const payload = new Uint8Array(iv.length + encrypted.length);
  payload.set(iv);
  payload.set(encrypted, iv.length);
  return `\\x${Array.from(payload, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export async function sha256Hex(data: ArrayBuffer): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", data));
}

export function safeFileName(filename: string): string {
  const cleaned = filename.normalize("NFKD").replace(/[^a-zA-Z0-9._-]/g, "_").replace(/_+/g, "_");
  return (cleaned || "document").slice(0, 120);
}

export { toBase64 };
