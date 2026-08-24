import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type CombineRequest = { statementIds?: string[] };

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;

  try {
    const { client } = await requireUser(request);
    const body = await readJson<CombineRequest>(request);
    const statementIds = [...new Set(body.statementIds ?? [])];
    if (statementIds.length < 2 || statementIds.length > 10) {
      return errorResponse(request, 400, "invalid_statement_ids", "Provide between 2 and 10 statements.");
    }

    const { data: allowed, error: accessError } = await client
      .from("statements")
      .select("id,pdf_object_path")
      .in("id", statementIds);
    if (accessError) throw accessError;
    if (!allowed || allowed.length !== statementIds.length) {
      return errorResponse(request, 404, "statement_not_found", "One or more statements were not found.");
    }

    const byId = new Map(allowed.map((row) => [row.id, row]));
    if (statementIds.some((id) => !byId.get(id)?.pdf_object_path)) {
      return errorResponse(request, 409, "statement_pdf_missing", "Generate every statement before combining them.");
    }

    const admin = serviceClient();
    const combined = await PDFDocument.create();
    for (const statementId of statementIds) {
      const objectPath = byId.get(statementId)!.pdf_object_path as string;
      const { data: file, error: downloadError } = await admin.storage
        .from("statements")
        .download(objectPath);
      if (downloadError || !file) throw downloadError ?? new Error("statement_download_failed");
      const source = await PDFDocument.load(await file.arrayBuffer());
      const pages = await combined.copyPages(source, source.getPageIndices());
      pages.forEach((page) => combined.addPage(page));
    }

    const pageFont = await combined.embedFont(StandardFonts.Helvetica);
    const pages = combined.getPages();
    pages.forEach((page, index) => {
      const label = `${index + 1} / ${pages.length}`;
      page.drawRectangle({ x: page.getWidth() / 2 - 22, y: 8, width: 44, height: 12, color: rgb(1, 1, 1) });
      page.drawText(label, { x: page.getWidth() / 2 - pageFont.widthOfTextAtSize(label, 7) / 2, y: 14, size: 7, font: pageFont, color: rgb(0.42, 0.45, 0.5) });
    });

    const bytes = await combined.save();
    const firstStatementId = statementIds[0];
    const objectPath = `statements/${firstStatementId}/${crypto.randomUUID()}-all-currencies.pdf`;
    const hash = await sha256Hex(bytes.buffer as ArrayBuffer);
    const { error: uploadError } = await admin.storage.from("statements").upload(objectPath, bytes, {
      contentType: "application/pdf",
      upsert: true,
    });
    if (uploadError) throw uploadError;

    const { error: attachError } = await admin.rpc("service_attach_statement_document", {
      p_statement_id: firstStatementId,
      p_object_path: objectPath,
      p_sha256_hex: hash,
    });
    if (attachError) throw attachError;

    const { data: signed, error: signError } = await admin.storage.from("statements").createSignedUrl(objectPath, 3600);
    if (signError || !signed) throw signError ?? new Error("signed_url_failed");
    const forwardedHost = request.headers.get("x-forwarded-host") ?? request.headers.get("host");
    const forwardedProto = request.headers.get("x-forwarded-proto") ?? "http";
    const requestOrigin = Deno.env.get("PUBLIC_API_URL") ?? (forwardedHost ? `${forwardedProto}://${forwardedHost}` : new URL(request.url).origin);
    const signedUrl = signed.signedUrl.replace(/^http:\/\/kong:8000/, requestOrigin);

    return json(request, { statementId: firstStatementId, pdfObjectPath: objectPath, signedUrl, sha256Hex: hash }, 201);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    if (message === "unauthorized") return errorResponse(request, 401, "unauthorized", "Authentication is required.");
    console.error("combine-statements failed:", error);
    return errorResponse(request, 500, "internal_error", "Unable to combine statement documents.");
  }
});
