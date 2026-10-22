export interface OpenWaTextInput {
  baseUrl: string;
  sessionId: string;
  apiKey: string;
  phone: string;
  text: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

/** Send one private text through OpenWA without exposing credentials to clients. */
export async function sendOpenWaText(
  input: OpenWaTextInput,
): Promise<Response> {
  const base = new URL(input.baseUrl);
  const localHttp = base.protocol === "http:" &&
    ["localhost", "127.0.0.1", "host.docker.internal"].includes(base.hostname);
  if (base.protocol !== "https:" && !localHttp) {
    throw new Error("openwa_https_required");
  }
  const phoneDigits = input.phone.replace(/\D/g, "");
  if (!/^\d{8,15}$/.test(phoneDigits)) {
    throw new Error("invalid_openwa_recipient");
  }
  if (!input.sessionId.trim() || !input.apiKey.trim()) {
    throw new Error("openwa_not_configured");
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), input.timeoutMs ?? 10_000);
  try {
    const endpoint = new URL(
      `/api/sessions/${encodeURIComponent(input.sessionId)}/messages/send-text`,
      base,
    );
    return await (input.fetchImpl ?? fetch)(endpoint, {
      method: "POST",
      redirect: "error",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": input.apiKey,
      },
      body: JSON.stringify({
        chatId: `${phoneDigits}@c.us`,
        text: input.text,
      }),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}
