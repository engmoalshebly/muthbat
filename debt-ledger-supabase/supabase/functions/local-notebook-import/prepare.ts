import { encryptPhone, phoneHash } from "../_shared/crypto.ts";
import { normalizeCustomerPhone } from "../_shared/customer-phone.ts";

type Row = Record<string, unknown>;

// Reuse the directory's Yemen default. Generic import commands and new
// immutable receipts contain no cleartext phone numbers.
export function normalizeNotebookPhone(raw: string): string {
  return normalizeCustomerPhone(raw);
}

export async function prepareNotebook(notebook: Row, userId: string) {
  if (notebook.owner_id !== userId || !Array.isArray(notebook.customers)
    || !Array.isArray(notebook.entries) || notebook.customers.length > 5000
    || notebook.entries.length > 20000) throw new Error("invalid_notebook");
  const customers: Row[] = [];
  const contacts: Record<string, Row> = {};
  const phones = new Set<string>();
  const ids = new Set<string>();
  const keyVersion = Number(Deno.env.get("PHONE_KEY_VERSION") ?? "1");
  if (!Number.isInteger(keyVersion) || keyVersion < 1) throw new Error("invalid_phone_key_version");
  for (const value of notebook.customers) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_notebook");
    const row = value as Row;
    if (typeof row.id !== "string" || ids.has(row.id)
      || typeof row.name !== "string"
      || (row.description != null && (typeof row.description !== "string" || row.description.length > 500))
      || (row.phone != null && typeof row.phone !== "string")) throw new Error("invalid_notebook");
    ids.add(row.id);
    const customer: Row = { id: row.id, name: row.name };
    if (row.description != null) customer.description = row.description;
    if (typeof row.phone === "string" && row.phone.trim()) {
      const phone = normalizeNotebookPhone(row.phone);
      const hash = await phoneHash(phone);
      if (phones.has(hash)) throw new Error("duplicate_phone");
      phones.add(hash);
      customer.phone_hash = hash;
      const encrypted = await encryptPhone(phone);
      // JSON carries bytea as a single literal \x prefix. The shared helper
      // also supports SQL-escaped output; do not persist that extra escape.
      const ciphertext = encrypted.startsWith("\\\\x") ? encrypted.slice(1) : encrypted;
      contacts[row.id] = {
        phone_hash: hash, phone_ciphertext: ciphertext,
        phone_last4: phone.slice(-4), key_version: keyVersion,
      };
    }
    customers.push(customer);
  }
  return {
    notebook: {
      id: notebook.id, version: notebook.version, owner_id: userId,
      name: notebook.name, currency: notebook.currency,
      customers, entries: notebook.entries,
    },
    contacts,
  };
}
