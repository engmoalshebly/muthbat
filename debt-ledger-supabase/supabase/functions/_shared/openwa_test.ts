import { sendOpenWaText } from "./openwa.ts";

Deno.test("OpenWA OTP delivery uses the configured session and normalized private JID", async () => {
  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;
  const response = await sendOpenWaText({
    baseUrl: "https://notify.prideidea.com/",
    sessionId: "test/session",
    apiKey: "server-only-test-key",
    phone: "+967 777 123 456",
    text: "رمز التحقق: 123456",
    fetchImpl: async (input, init) => {
      capturedUrl = String(input);
      capturedInit = init;
      return new Response("{}", { status: 201 });
    },
  });

  if (response.status !== 201) {
    throw new Error("OpenWA response was not returned");
  }
  if (
    capturedUrl !==
      "https://notify.prideidea.com/api/sessions/test%2Fsession/messages/send-text"
  ) {
    throw new Error(`Unexpected OpenWA endpoint: ${capturedUrl}`);
  }
  const headers = new Headers(capturedInit?.headers);
  if (capturedInit?.redirect !== "error") {
    throw new Error("Gateway redirects must not forward credentials");
  }
  if (headers.get("X-API-Key") !== "server-only-test-key") {
    throw new Error("Missing server API key header");
  }
  if (headers.has("Authorization")) {
    throw new Error("Unexpected Authorization header");
  }
  const body = JSON.parse(String(capturedInit?.body));
  if (
    body.chatId !== "967777123456@c.us" || body.text !== "رمز التحقق: 123456"
  ) {
    throw new Error("OpenWA recipient or message body was malformed");
  }
});

Deno.test("OpenWA rejects insecure hosted URLs", async () => {
  let failed = false;
  try {
    await sendOpenWaText({
      baseUrl: "http://notify.example.com",
      sessionId: "session",
      apiKey: "test-key",
      phone: "+967777123456",
      text: "test",
      fetchImpl: async () => new Response(null, { status: 201 }),
    });
  } catch {
    failed = true;
  }
  if (!failed) throw new Error("Insecure hosted OpenWA URL was accepted");
});
