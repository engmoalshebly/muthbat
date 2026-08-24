import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { safeFileName } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type UploadRequest = { entityType: "ledger_entry" | "dispute_message"; entityId: string; filename: string; mimeType: string; sizeBytes: number; sha256Hex?: string };
const allowedMimeTypes = new Set(["image/jpeg", "image/png", "image/webp", "application/pdf"]);
// Write-capable roles, matching the ledger-entry creation matrix (202608140010).
const writeRoles = ["owner", "admin", "accountant", "cashier"];

type AdminClient = ReturnType<typeof serviceClient>;

async function isBusinessWriter(admin: AdminClient, businessId: string, userId: string): Promise<boolean> {
  const { data, error } = await admin.from("business_members").select("id")
    .eq("business_id", businessId).eq("user_id", userId).eq("status", "active")
    .in("role", writeRoles).maybeSingle();
  return !error && Boolean(data);
}

async function isLinkedCustomerOwner(admin: AdminClient, businessId: string, customerId: string, userId: string): Promise<boolean> {
  const { data: customer, error } = await admin.from("customers").select("id")
    .eq("id", customerId).eq("user_id", userId).eq("status", "active").maybeSingle();
  if (error || !customer) return false;
  const { data: link, error: linkError } = await admin.from("business_customers").select("id")
    .eq("business_id", businessId).eq("customer_id", customerId).eq("link_status", "linked").maybeSingle();
  return !linkError && Boolean(link);
}

// Write authorization (fix-plan/03 step 4.1): read access via RLS is not enough —
// attaching requires a write role on the business, or being the linked customer
// party of a dispute. Mirrors the planned private.can_attach_to_ledger_entry RPC
// (migration 0016); switch to that RPC once the migration lands.
async function canAttachToEntity(admin: AdminClient, userId: string, entityType: string, entityId: string): Promise<boolean> {
  if (entityType === "ledger_entry") {
    const { data: entry, error } = await admin.from("ledger_entries").select("business_id").eq("id", entityId).maybeSingle();
    if (error || !entry) return false;
    return isBusinessWriter(admin, entry.business_id, userId);
  }
  const { data: message, error } = await admin.from("dispute_messages").select("disputes(business_id,customer_id)").eq("id", entityId).maybeSingle();
  const relatedDisputes = message?.disputes;
  const dispute = (Array.isArray(relatedDisputes) ? relatedDisputes[0] : relatedDisputes) as { business_id: string; customer_id: string } | null;
  if (error || !dispute) return false;
  if (await isBusinessWriter(admin, dispute.business_id, userId)) return true;
  return isLinkedCustomerOwner(admin, dispute.business_id, dispute.customer_id, userId);
}

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;
  try {
    const auth = await requireUser(request);
    const input = await readJson<UploadRequest>(request);
    if (!input.entityId || !["ledger_entry", "dispute_message"].includes(input.entityType) || !allowedMimeTypes.has(input.mimeType) || !Number.isInteger(input.sizeBytes) || input.sizeBytes < 1 || input.sizeBytes > 10_485_760) {
      return errorResponse(request, 422, "invalid_upload", "The document metadata is invalid.");
    }
    if (input.sha256Hex !== undefined && !/^[0-9a-f]{64}$/i.test(input.sha256Hex)) {
      return errorResponse(request, 422, "invalid_sha256", "sha256Hex must be a 64-character hex string.");
    }
    const admin = serviceClient();
    if (!await canAttachToEntity(admin, auth.user.id, input.entityType, input.entityId)) {
      return errorResponse(request, 403, "forbidden", "You cannot attach a document to this entity.");
    }
    const sessionId = crypto.randomUUID();
    const objectPath = `${input.entityType}/${input.entityId}/${crypto.randomUUID()}-${safeFileName(input.filename)}`;
    const { error: sessionError } = await admin.from("upload_sessions").insert({
      id: sessionId, user_id: auth.user.id, entity_type: input.entityType, entity_id: input.entityId,
      object_path: objectPath, original_filename: input.filename, mime_type: input.mimeType,
      expected_size_bytes: input.sizeBytes, expected_sha256_hex: input.sha256Hex?.toLowerCase() ?? null,
    });
    if (sessionError) throw sessionError;
    const { data, error } = await admin.storage.from("ledger-documents").createSignedUploadUrl(objectPath);
    if (error || !data) throw error ?? new Error("signed_upload_failed");
    return json(request, { uploadSessionId: sessionId, bucketId: "ledger-documents", objectPath, token: data.token, signedUrl: data.signedUrl, expiresInSeconds: 900 }, 201);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    return errorResponse(request, message === "unauthorized" ? 401 : 400, message, "Unable to create a document upload session.");
  }
});
