import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type FinalizeRequest = { uploadSessionId: string };

// Write-capable roles, matching the ledger-entry creation matrix (202608140010).
const writeRoles = ["owner", "admin", "accountant", "cashier"];

// Binary signatures for the allowed mime types (fix-plan/03 step 4.2).
const magicBytes: Record<string, number[][]> = {
  "image/jpeg": [[0xFF, 0xD8, 0xFF]],
  "image/png": [[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]],
  "image/webp": [[0x52, 0x49, 0x46, 0x46]], // "RIFF", plus "WEBP" at offset 8
  "application/pdf": [[0x25, 0x50, 0x44, 0x46]], // "%PDF"
};

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

function matchesMagicBytes(bytes: Uint8Array, mimeType: string): boolean {
  const signatures = magicBytes[mimeType];
  if (!signatures || bytes.byteLength < 12) return false;
  const matches = signatures.some((signature) => signature.every((byte, index) => bytes[index] === byte));
  if (!matches) return false;
  if (mimeType === "image/webp") {
    // "WEBP" at offset 8 distinguishes WebP from other RIFF containers.
    return bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50;
  }
  return true;
}

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;
  try {
    const auth = await requireUser(request);
    const { uploadSessionId } = await readJson<FinalizeRequest>(request);
    if (!uploadSessionId) return errorResponse(request, 422, "invalid_request", "uploadSessionId is required.");
    const admin = serviceClient();
    const { data: session, error: sessionError } = await admin.from("upload_sessions").select("*").eq("id", uploadSessionId).eq("user_id", auth.user.id).is("consumed_at", null).single();
    if (sessionError || !session || new Date(session.expires_at).getTime() < Date.now()) return errorResponse(request, 404, "upload_session_not_found", "The upload session is missing or expired.");
    if (!await canAttachToEntity(admin, auth.user.id, session.entity_type, session.entity_id)) return errorResponse(request, 403, "forbidden", "You cannot finalize this document.");
    const { data: blob, error: downloadError } = await admin.storage.from(session.bucket_id).download(session.object_path);
    if (downloadError || !blob) throw downloadError ?? new Error("document_not_found");
    const bytes = await blob.arrayBuffer();
    if (bytes.byteLength !== Number(session.expected_size_bytes)) return errorResponse(request, 422, "file_size_mismatch", "The uploaded file size does not match the request.");
    const hash = await sha256Hex(bytes);
    if (session.expected_sha256_hex && hash !== session.expected_sha256_hex) return errorResponse(request, 422, "file_hash_mismatch", "The uploaded file hash does not match the request.");
    if (!matchesMagicBytes(new Uint8Array(bytes), session.mime_type)) {
      // Reject spoofed content and remove the orphaned object from the bucket.
      await admin.storage.from(session.bucket_id).remove([session.object_path]);
      return errorResponse(request, 422, "file_content_mismatch", "The uploaded file content does not match its declared type.");
    }
    let businessId: string | null = null;
    let customerId: string | null = null;
    if (session.entity_type === "ledger_entry") {
      const { data: entry, error } = await admin.from("ledger_entries").select("business_id,customer_id").eq("id", session.entity_id).single();
      if (error || !entry) throw error ?? new Error("entry_not_found");
      businessId = entry.business_id; customerId = entry.customer_id;
    } else {
      const { data: message, error } = await admin.from("dispute_messages").select("disputes(business_id,customer_id)").eq("id", session.entity_id).single();
      const relatedDisputes = message?.disputes;
      const dispute = (Array.isArray(relatedDisputes) ? relatedDisputes[0] : relatedDisputes) as { business_id: string; customer_id: string } | null;
      if (error || !dispute) throw error ?? new Error("dispute_message_not_found");
      businessId = dispute.business_id; customerId = dispute.customer_id;
    }
    const { data: file, error: fileError } = await admin.from("files").insert({
      business_id: businessId, customer_id: customerId, bucket_id: session.bucket_id, object_path: session.object_path,
      original_filename: session.original_filename, mime_type: session.mime_type, size_bytes: bytes.byteLength,
      sha256_hex: hash, uploaded_by_user_id: auth.user.id,
    }).select("id").single();
    if (fileError || !file) throw fileError ?? new Error("file_metadata_failed");
    const linkTable = session.entity_type === "ledger_entry" ? "ledger_entry_files" : "dispute_message_files";
    const linkColumn = session.entity_type === "ledger_entry" ? "entry_id" : "message_id";
    const { error: linkError } = await admin.from(linkTable).insert({ [linkColumn]: session.entity_id, file_id: file.id });
    if (linkError) throw linkError;
    const { error: consumeError } = await admin.from("upload_sessions").update({ consumed_at: new Date().toISOString() }).eq("id", session.id });
    if (consumeError) throw consumeError;
    return json(request, { fileId: file.id, sha256Hex: hash }, 201);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    return errorResponse(request, message === "unauthorized" ? 401 : 400, message, "Unable to finalize the document upload.");
  }
});
