import { PDFDocument, rgb } from "npm:pdf-lib@1.17.1";
import fontkit from "npm:@pdf-lib/fontkit@1.1.1";
import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type GenerateStatementRequest = {
  statementId?: string;
  scope?: "business_customer" | "customer_consolidated";
  businessCustomerId?: string;
  periodFrom?: string;
  periodTo?: string;
};

type StatementHeader = {
  id: string;
  scope: "business_customer" | "customer_consolidated";
  business_id: string | null;
  business_customer_id: string | null;
  customer_id: string;
  period_from: string;
  period_to: string;
  currency_code: string;
  opening_balance: number;
  total_debits: number;
  total_credits: number;
  closing_balance: number;
  verification_code: string;
  snapshot_sha256_hex: string | null;
  pdf_object_path: string | null;
  created_at: string;
};

type StatementItem = {
  item_order: number;
  occurred_at: string;
  description_snapshot: string;
  debit_amount: number;
  credit_amount: number;
  running_balance: number;
  confirmation_status: string;
};

type BusinessInfo = {
  name: string;
  businessType?: string | null;
  city?: string | null;
  address?: string | null;
  contactPhone?: string | null;
};

type CustomerInfo = {
  name: string;
  phoneLast4?: string | null;
  globalCode?: string | null;
  note?: string | null;
};

const tajawalRegularUrl =
  "https://raw.githubusercontent.com/google/fonts/main/ofl/tajawal/Tajawal-Regular.ttf";
const tajawalBoldUrl =
  "https://raw.githubusercontent.com/google/fonts/main/ofl/tajawal/Tajawal-Bold.ttf";

async function fetchFont(url: string): Promise<Uint8Array> {
  const response = await fetch(url);
  if (!response.ok) throw new Error("statement_font_unavailable");
  return new Uint8Array(await response.arrayBuffer());
}

function formatAmount(amount: number, currency: string): string {
  const formatted = Math.abs(amount).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  return currency ? `${formatted} ${currency}` : formatted;
}

// Signed variant for the running-balance column: a negative balance
// (advance payment / credit) must keep its minus sign in the official record.
function formatSignedAmount(amount: number, currency: string): string {
  const sign = amount < 0 ? "-" : "";
  return sign + formatAmount(amount, currency);
}

function formatDate(isoString: string): string {
  const d = new Date(isoString);
  return d.toISOString().split("T")[0];
}

function confirmationLabel(status: string): string {
  const labels: Record<string, string> = {
    confirmed: "مؤكد",
    pending: "بانتظار التأكيد",
    rejected: "مرفوض",
    no_available: "غير متاح",
    not_available: "غير متاح",
  };
  return labels[status] ?? status;
}

async function buildStatementPdf(
  header: StatementHeader,
  items: StatementItem[],
  business: BusinessInfo,
  customer: CustomerInfo,
  businessLogo?: { bytes: Uint8Array; extension: string } | null,
  platformLogoBytes?: Uint8Array | null,
): Promise<Uint8Array> {
  const pdfDoc = await PDFDocument.create();
  pdfDoc.registerFontkit(fontkit);
  const [regularBytes, boldBytes] = await Promise.all([
    fetchFont(tajawalRegularUrl),
    fetchFont(tajawalBoldUrl),
  ]);
  const fontRegular = await pdfDoc.embedFont(regularBytes, { subset: false });
  const fontBold = await pdfDoc.embedFont(boldBytes, { subset: false });
  const drawRight = (
    target: any,
    text: string,
    right: number,
    baseline: number,
    size: number,
    font = fontRegular,
    color = rgb(0.1, 0.12, 0.15),
  ) => target.drawText(text, {
    x: right - font.widthOfTextAtSize(text, size),
    y: baseline,
    size,
    font,
    color,
  });

  // A4 dimensions: 595.28 x 841.89 points
  const pageWidth = 595.28;
  const pageHeight = 841.89;
  const margin = 40;
  const contentWidth = pageWidth - margin * 2;

  let page = pdfDoc.addPage([pageWidth, pageHeight]);
  let y = pageHeight - margin;

  const drawCentered = (text: string, centerX: number, baselineY: number, size: number, selectedFont = fontRegular, color = rgb(0.1, 0.1, 0.1)) => {
    page.drawText(text, {
      x: centerX - selectedFont.widthOfTextAtSize(text, size) / 2,
      y: baselineY,
      size,
      font: selectedFont,
      color,
    });
  };

  // Simple accounting header inspired by traditional customer statements.
  let platformWatermark: any = null;
  if (platformLogoBytes) {
    try {
      platformWatermark = await pdfDoc.embedPng(platformLogoBytes);
      const fitted = platformWatermark.scaleToFit(175, 175);
      page.drawImage(platformWatermark, {
        x: (pageWidth - fitted.width) / 2,
        y: (pageHeight - fitted.height) / 2,
        width: fitted.width,
        height: fitted.height,
        opacity: 0.035,
      });
    } catch (error) {
      console.warn("Unable to embed Muthbat watermark:", error);
    }
  }

  if (businessLogo) {
    try {
      const logo = businessLogo.extension === "png"
        ? await pdfDoc.embedPng(businessLogo.bytes)
        : await pdfDoc.embedJpg(businessLogo.bytes);
      const fitted = logo.scaleToFit(34, 34);
      page.drawImage(logo, {
        x: (pageWidth - fitted.width) / 2,
        y: y - 38,
        width: fitted.width,
        height: fitted.height,
      });
    } catch (error) {
      console.warn("Unable to embed business logo in statement:", error);
    }
  } else {
    page.drawCircle({
      x: pageWidth / 2,
      y: y - 21,
      size: 16,
      color: rgb(0.94, 0.95, 0.97),
    });
    const initial = business.name.trim().charAt(0) || "م";
    page.drawText(initial, {
      x: pageWidth / 2 - 5,
      y: y - 27,
      size: 14,
      font: fontBold,
      color: rgb(0.18, 0.23, 0.31),
    });
  }

  const businessLocation = [business.city, business.address].filter(Boolean).join(" - ");
  drawRight(page, business.name, pageWidth - margin, y - 12, 9, fontBold, rgb(0.12, 0.18, 0.26));
  drawRight(page, business.businessType || "غير محدد", pageWidth - margin, y - 25, 6.8, fontRegular, rgb(0.35, 0.38, 0.42));
  drawRight(page, business.contactPhone || "غير محدد", pageWidth - margin, y - 37, 6.8, fontRegular, rgb(0.35, 0.38, 0.42));
  drawRight(page, businessLocation || "غير محدد", pageWidth - margin, y - 49, 6.5, fontRegular, rgb(0.42, 0.45, 0.48));

  drawRight(page, customer.name, margin + 140, y - 12, 8, fontBold, rgb(0.12, 0.18, 0.26));
  drawRight(page, customer.globalCode || "-", margin + 140, y - 27, 6.8, fontRegular, rgb(0.35, 0.38, 0.42));
  drawRight(page, customer.phoneLast4 ? `***${customer.phoneLast4}` : "غير محدد", margin + 140, y - 40, 6.8, fontRegular, rgb(0.35, 0.38, 0.42));

  drawCentered(`كشف حساب - ${customer.name}`, pageWidth / 2, y - 66, 11, fontBold, rgb(0.08, 0.25, 0.55));
  page.drawLine({ start: { x: pageWidth / 2 - 72, y: y - 70 }, end: { x: pageWidth / 2 + 72, y: y - 70 }, thickness: 0.5, color: rgb(0.08, 0.25, 0.55) });

  page.drawRectangle({ x: margin, y: y - 92, width: contentWidth, height: 18, borderColor: rgb(0.35, 0.38, 0.42), borderWidth: 0.6 });
  drawRight(page, "من", pageWidth / 2 + 142, y - 86, 7.5, fontBold, rgb(0.08, 0.25, 0.55));
  page.drawText(formatDate(header.period_from), { x: pageWidth / 2 + 35, y: y - 86, size: 7.5, font: fontBold, color: rgb(0.08, 0.25, 0.55) });
  drawRight(page, "إلى", pageWidth / 2 - 18, y - 86, 7.5, fontBold, rgb(0.08, 0.25, 0.55));
  page.drawText(formatDate(header.period_to), { x: pageWidth / 2 - 128, y: y - 86, size: 7.5, font: fontBold, color: rgb(0.08, 0.25, 0.55) });

  page.drawRectangle({ x: margin, y: y - 116, width: contentWidth, height: 20, color: rgb(0.97, 0.97, 0.97), borderColor: rgb(0.5, 0.52, 0.54), borderWidth: 0.5 });
  const summaryWidth = contentWidth / 4;
  const simpleSummary = [
    { label: "الرصيد المستحق", value: Math.abs(header.closing_balance), color: rgb(0.75, 0.12, 0.1) },
    { label: "إجمالي له", value: header.total_credits, color: rgb(0.08, 0.45, 0.2) },
    { label: "إجمالي عليه", value: header.total_debits, color: rgb(0.75, 0.12, 0.1) },
    { label: "الرصيد الافتتاحي", value: header.opening_balance, color: rgb(0.2, 0.23, 0.27) },
  ];
  simpleSummary.forEach((entry, index) => {
    const cellX = pageWidth - margin - (index + 1) * summaryWidth;
    if (index > 0) page.drawLine({ start: { x: cellX, y: y - 115 }, end: { x: cellX, y: y - 97 }, thickness: 0.4, color: rgb(0.65, 0.67, 0.69) });
    drawRight(page, entry.label, cellX + summaryWidth - 7, y - 109, 6.2, fontRegular, rgb(0.35, 0.38, 0.42));
    page.drawText(formatAmount(entry.value, header.currency_code), { x: cellX + 6, y: y - 109, size: 6.7, font: fontBold, color: entry.color });
  });

  y -= 121;

  // Table Header
  page.drawRectangle({
    x: margin,
    y: y - 20,
    width: contentWidth,
    height: 20,
    color: rgb(0.2, 0.25, 0.32),
  });

  const colRight = {
    balance: margin + 75,
    credit: margin + 150,
    debit: margin + 225,
    desc: margin + 425,
    date: pageWidth - margin - 7,
  };
  const tableBoundaries = [margin, margin + 82, margin + 157, margin + 232, margin + 432, pageWidth - margin];

  drawRight(page, "التاريخ", colRight.date, y - 14, 7.5, fontBold, rgb(1, 1, 1));
  drawRight(page, "التفاصيل", colRight.desc, y - 14, 7.5, fontBold, rgb(1, 1, 1));
  drawRight(page, "عليه", colRight.debit, y - 14, 7.5, fontBold, rgb(1, 1, 1));
  drawRight(page, "له", colRight.credit, y - 14, 7.5, fontBold, rgb(1, 1, 1));
  drawRight(page, "الرصيد", colRight.balance, y - 14, 7.5, fontBold, rgb(1, 1, 1));
  tableBoundaries.slice(1, -1).forEach((boundary) => page.drawLine({ start: { x: boundary, y: y }, end: { x: boundary, y: y - 20 }, thickness: 0.4, color: rgb(0.62, 0.67, 0.73) }));

  y -= 22;

  // Render Table Rows
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const description = item.description_snapshot.trim() || "حركة مالية";
    const descriptionLines = description.length > 32
      ? [description.slice(0, 32), description.slice(32, 64)]
      : [description];
    const rowHeight = descriptionLines.length > 1 ? 27 : 19;

    // Check if new page is needed
    if (y < margin + 60) {
      page = pdfDoc.addPage([pageWidth, pageHeight]);
      y = pageHeight - margin;

      if (platformWatermark) {
        const fitted = platformWatermark.scaleToFit(175, 175);
        page.drawImage(platformWatermark, {
          x: (pageWidth - fitted.width) / 2,
          y: (pageHeight - fitted.height) / 2,
          width: fitted.width,
          height: fitted.height,
          opacity: 0.035,
        });
      }

      // Table Header on New Page
      page.drawRectangle({
        x: margin,
        y: y - 20,
        width: contentWidth,
        height: 20,
        color: rgb(0.2, 0.25, 0.32),
      });

      drawRight(page, "التاريخ", colRight.date, y - 14, 7.5, fontBold, rgb(1, 1, 1));
      drawRight(page, "التفاصيل", colRight.desc, y - 14, 7.5, fontBold, rgb(1, 1, 1));
      drawRight(page, "عليه", colRight.debit, y - 14, 7.5, fontBold, rgb(1, 1, 1));
      drawRight(page, "له", colRight.credit, y - 14, 7.5, fontBold, rgb(1, 1, 1));
      drawRight(page, "الرصيد", colRight.balance, y - 14, 7.5, fontBold, rgb(1, 1, 1));
      tableBoundaries.slice(1, -1).forEach((boundary) => page.drawLine({ start: { x: boundary, y }, end: { x: boundary, y: y - 20 }, thickness: 0.4, color: rgb(0.62, 0.67, 0.73) }));
      y -= 22;
    }

    const isEven = i % 2 === 0;
    if (isEven) {
      page.drawRectangle({
        x: margin,
        y: y - rowHeight + 4,
        width: contentWidth,
        height: rowHeight,
        color: rgb(0.98, 0.98, 0.99),
      });
    }
    page.drawLine({
      start: { x: margin, y: y - rowHeight + 4 },
      end: { x: pageWidth - margin, y: y - rowHeight + 4 },
      thickness: 0.35,
      color: rgb(0.88, 0.9, 0.92),
    });

    tableBoundaries.forEach((boundary) => page.drawLine({ start: { x: boundary, y: y + 4 }, end: { x: boundary, y: y - rowHeight + 4 }, thickness: 0.35, color: rgb(0.72, 0.74, 0.77) }));

    drawRight(page, formatDate(item.occurred_at), colRight.date, y - 8, 7.5, fontRegular, rgb(0.2, 0.2, 0.2));

    drawRight(page, descriptionLines[0], colRight.desc, y - 8, 7.5, fontRegular, rgb(0.1, 0.1, 0.1));
    if (descriptionLines[1]) {
      drawRight(page, descriptionLines[1], colRight.desc, y - 18, 6.8, fontRegular, rgb(0.35, 0.35, 0.38));
    }

    drawRight(page, item.debit_amount > 0 ? formatAmount(item.debit_amount, "") : "-", colRight.debit, y - 8, 7.5, fontRegular, item.debit_amount > 0 ? rgb(0.7, 0.15, 0.1) : rgb(0.5, 0.5, 0.5));
    drawRight(page, item.credit_amount > 0 ? formatAmount(item.credit_amount, "") : "-", colRight.credit, y - 8, 7.5, fontRegular, item.credit_amount > 0 ? rgb(0.1, 0.5, 0.2) : rgb(0.5, 0.5, 0.5));
    drawRight(page, formatSignedAmount(item.running_balance, ""), colRight.balance, y - 8, 7.5, fontBold, item.running_balance < 0 ? rgb(0.1, 0.5, 0.25) : rgb(0.1, 0.1, 0.1));

    y -= rowHeight;
  }

  const pageCount = pdfDoc.getPageCount();
  pdfDoc.getPages().forEach((pdfPage, index) => {
    pdfPage.drawLine({
      start: { x: margin, y: 25 },
      end: { x: pageWidth - margin, y: 25 },
      thickness: 0.5,
      color: rgb(0.82, 0.84, 0.88),
    });
    drawRight(pdfPage, "مُثبَت — كشف حساب", pageWidth - margin, 14, 7, fontBold, rgb(0.42, 0.45, 0.5));
    pdfPage.drawText(`${index + 1} / ${pageCount}`, { x: pageWidth / 2 - 10, y: 14, size: 7, font: fontRegular, color: rgb(0.42, 0.45, 0.5) });
    pdfPage.drawText(header.verification_code, { x: margin, y: 14, size: 6.5, font: fontRegular, color: rgb(0.42, 0.45, 0.5) });
  });

  return await pdfDoc.save();
}

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;

  const methodError = requirePost(request);
  if (methodError) return methodError;

  try {
    const { user, client } = await requireUser(request);
    const body = await readJson<GenerateStatementRequest>(request).catch(() => ({} as GenerateStatementRequest));

    let statementId = body.statementId;

    // Step 1: If no statementId provided, create statement snapshot using database RPC
    if (!statementId) {
      const scope = body.scope ?? "business_customer";
      const periodFrom = body.periodFrom ?? new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
      const periodTo = body.periodTo ?? new Date().toISOString();

      const { data: createdId, error: createError } = await client.rpc("create_statement", {
        p_scope: scope,
        p_business_customer_id: body.businessCustomerId ?? null,
        p_period_from: periodFrom,
        p_period_to: periodTo,
      });

      if (createError || !createdId) {
        console.error("create_statement RPC failed:", createError);
        throw new Error("statement_creation_failed");
      }
      statementId = createdId;
    } else {
      // Ownership check for a caller-supplied statementId, via the RLS-scoped
      // user client (SELECT policies on statements enforce party membership).
      // Must run before any service-client fetch. Returns 404 (not 403) to
      // prevent statement ID enumeration.
      const { data: allowed, error: accessError } = await client
        .from("statements")
        .select("id")
        .eq("id", statementId)
        .maybeSingle();
      if (accessError) throw accessError;
      if (!allowed) {
        return errorResponse(request, 404, "statement_not_found", "Statement snapshot not found.");
      }
    }

    const admin = serviceClient();

    // Step 2: Fetch Statement Header
    const { data: header, error: headerError } = await admin
      .from("statements")
      .select("*")
      .eq("id", statementId)
      .single();

    if (headerError || !header) {
      console.error("statement header fetch failed", {
        statementId,
        code: headerError?.code,
        message: headerError?.message,
      });
      return errorResponse(request, 404, "statement_not_found", "Statement snapshot not found.");
    }

    // Step 3: Fetch Statement Items
    const { data: items, error: itemsError } = await admin
      .from("statement_items")
      .select("*")
      .eq("statement_id", statementId)
      .order("item_order", { ascending: true });

    if (itemsError) throw itemsError;

    // Step 4: Resolve Entity Names for Display
    let business: BusinessInfo = { name: "Consolidated Accounts" };
    let businessLogo: { bytes: Uint8Array; extension: string } | null = null;
    let platformLogoBytes: Uint8Array | null = null;
    let customer: CustomerInfo = { name: `Customer (${header.customer_id.slice(0, 8)})` };

    const { data: platformLogoFile } = await admin.storage
      .from("business-assets")
      .download("platform/muthbat-icon.png");
    if (platformLogoFile) {
      platformLogoBytes = new Uint8Array(await platformLogoFile.arrayBuffer());
    }

    if (header.business_id) {
      const { data: businessRow } = await admin
        .from("businesses")
        .select("name,business_type,city,address,contact_phone_display,logo_path")
        .eq("id", header.business_id)
        .maybeSingle();
      if (businessRow) {
        business = {
          name: businessRow.name,
          businessType: businessRow.business_type,
          city: businessRow.city,
          address: businessRow.address,
          contactPhone: businessRow.contact_phone_display,
        };
      }
      if (businessRow?.logo_path) {
        const { data: logoFile } = await admin.storage
          .from("business-assets")
          .download(businessRow.logo_path);
        if (logoFile) {
          businessLogo = {
            bytes: new Uint8Array(await logoFile.arrayBuffer()),
            extension: businessRow.logo_path.toLowerCase().endsWith(".png")
              ? "png"
              : "jpg",
          };
        }
      }
    }

    if (header.business_customer_id) {
      const { data: busCust } = await admin
        .from("business_customers")
        .select("local_display_name,local_note,customers(global_code)")
        .eq("id", header.business_customer_id)
        .maybeSingle();
      if (busCust?.local_display_name) {
        const customerRecord = Array.isArray(busCust.customers)
          ? busCust.customers[0]
          : busCust.customers;
        customer = {
          name: busCust.local_display_name,
          note: busCust.local_note,
          globalCode: customerRecord?.global_code,
        };
      }
    } else {
      const { data: custProfile } = await admin
        .from("profiles")
        .select("display_name")
        .eq("id", user.id)
        .maybeSingle();
      if (custProfile?.display_name) customer = { name: custProfile.display_name };
    }

    // Step 5: Render PDF Document
    const pdfBytes = await buildStatementPdf(
      header as StatementHeader,
      (items ?? []) as StatementItem[],
      business,
      customer,
      businessLogo,
      platformLogoBytes,
    );

    const hash = await sha256Hex(pdfBytes.buffer as ArrayBuffer);
    // The verification code stays in the database only; a signed-URL holder
    // must not implicitly learn the public verification code from the path.
    const objectPath = `statements/${header.id}/${crypto.randomUUID()}.pdf`;

    // Step 6: Upload PDF to Supabase Storage bucket 'statements'
    const { error: uploadError } = await admin.storage
      .from("statements")
      .upload(objectPath, pdfBytes, {
        contentType: "application/pdf",
        upsert: true,
      });

    if (uploadError) throw uploadError;

    // Step 7: Lock PDF metadata and hash in database
    const { error: attachError } = await admin.rpc("service_attach_statement_document", {
      p_statement_id: header.id,
      p_object_path: objectPath,
      p_sha256_hex: hash,
    });

    if (attachError) throw attachError;

    // Step 8: Create Signed Download URL
    const { data: signedData, error: signError } = await admin.storage
      .from("statements")
      .createSignedUrl(objectPath, 3600);

    if (signError || !signedData) throw signError ?? new Error("signed_url_failed");
    const forwardedHost = request.headers.get("x-forwarded-host")
      ?? request.headers.get("host");
    const forwardedProto = request.headers.get("x-forwarded-proto") ?? "http";
    const forwardedPort = request.headers.get("x-forwarded-port");
    const publicHost = forwardedHost && forwardedPort && !forwardedHost.includes(":")
      ? `${forwardedHost}:${forwardedPort}`
      : forwardedHost;
    const requestOrigin = Deno.env.get("PUBLIC_API_URL") ?? (publicHost
      ? `${forwardedProto}://${publicHost}`
      : new URL(request.url).origin);
    const publicSignedUrl = signedData.signedUrl.replace(
      /^http:\/\/kong:8000/,
      requestOrigin,
    );

    return json(
      request,
      {
        statementId: header.id,
        // verificationCode intentionally omitted — it stays in the database
        // only and is validated via the public verify-statement endpoint.
        // Exposing it here would let a PDF holder bypass the verification chain.
        scope: header.scope,
        periodFrom: header.period_from,
        periodTo: header.period_to,
        currencyCode: header.currency_code,
        openingBalance: header.opening_balance,
        totalDebits: header.total_debits,
        totalCredits: header.total_credits,
        closingBalance: header.closing_balance,
        pdfObjectPath: objectPath,
        signedUrl: publicSignedUrl,
        sha256Hex: hash,
      },
      201,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    if (message === "unauthorized") {
      return errorResponse(request, 401, "unauthorized", "Authentication is required.");
    }
    // Whitelist of intentional error codes. Raw database/storage/RPC error
    // messages must never leak to the caller; they are logged server-side
    // and surfaced as a generic internal_error instead.
    const safeCodes: Record<string, number> = {
      invalid_json: 400,
      statement_creation_failed: 400,
      signed_url_failed: 502,
      statement_font_unavailable: 503,
    };
    const status = safeCodes[message];
    if (status) {
      return errorResponse(request, status, message, "Unable to generate the statement document.");
    }
    console.error("generate-statement failed:", error);
    return errorResponse(request, 500, "internal_error", "Unable to generate the statement document.");
  }
});
