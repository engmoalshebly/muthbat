import { normalizeNotebookPhone, prepareNotebook } from "./prepare.ts";

function assert(value: unknown, message: string) {
  if (!value) throw new Error(message);
}
const base = { id: "notebook", version: 1, owner_id: "owner", name: "shop", currency: "YER", entries: [] };
Deno.test("normalizes local and international numbers without changing international country", () => {
  assert(normalizeNotebookPhone("777123456") === "+967777123456", "Yemen default");
  assert(normalizeNotebookPhone("967777123456") === "+967777123456", "country prefix");
  assert(normalizeNotebookPhone("966501234567") === "+966501234567", "legacy stored international number");
  assert(normalizeNotebookPhone("00966 50-123-4567") === "+966501234567", "international prefix");
});
Deno.test("preparation preserves notes, encrypts phone, and yields stable retry snapshots", async () => {
  Deno.env.set("PHONE_HMAC_KEY", btoa("a".repeat(32)));
  Deno.env.set("PHONE_ENCRYPTION_KEY", btoa("b".repeat(32)));
  const input = { ...base, customers: [{ id: "customer", name: "أحمد", phone: "777123456", description: "عنوان العميل" }] };
  const first = await prepareNotebook(input, "owner");
  const retry = await prepareNotebook(input, "owner");
  assert(JSON.stringify(first.notebook) === JSON.stringify(retry.notebook), "stable snapshot");
  assert(!JSON.stringify(first).includes("777123456"), "no raw phone in staged data");
  assert(first.notebook.customers[0].description === "عنوان العميل", "description preserved");
  assert(first.contacts.customer.phone_last4 === "3456", "masked phone retained");
  assert(first.contacts.customer.phone_ciphertext !== retry.contacts.customer.phone_ciphertext, "fresh encryption IV");
  const ciphertext = first.contacts.customer.phone_ciphertext as string;
  assert(/^\\x[0-9a-f]+$/.test(ciphertext), "canonical PostgreSQL bytea prefix");
  const bytes = Uint8Array.from(ciphertext.slice(2).match(/../g)!, (hex) => parseInt(hex, 16));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("b".repeat(32)), "AES-GCM", false, ["decrypt"]);
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, key, bytes.slice(12));
  assert(new TextDecoder().decode(clear) === "+967777123456", "stored bytes decrypt to original phone");
});
Deno.test("rejects duplicate normalized phones and foreign notebook owner before import", async () => {
  const input = { ...base, customers: [
    { id: "one", name: "one", phone: "777123456" },
    { id: "two", name: "two", phone: "+967777123456" },
  ] };
  for (const [notebook, owner, expected] of [[input, "owner", "duplicate_phone"], [input, "other", "invalid_notebook"]] as const) {
    let message = "";
    try { await prepareNotebook(notebook, owner); } catch (error) { message = (error as Error).message; }
    assert(message === expected, expected);
  }
});
