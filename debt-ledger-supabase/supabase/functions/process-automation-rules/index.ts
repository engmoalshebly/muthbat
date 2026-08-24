import { optionsResponse } from "../_shared/cors.ts";
import { requireWorkerSecret } from "../_shared/auth.ts";
import { errorResponse, json, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type AutomationRule = {
  id: string;
  business_id: string;
  rule_key: string;
  trigger_type: "before_due" | "on_due" | "after_due" | "dispute_sla";
  offset_days: number;
  channel: "in_app" | "push" | "manual_share";
  message_template: string;
  is_active: boolean;
};

type BusinessInfo = {
  id: string;
  name: string;
  currency_code: string;
  timezone: string;
  owner_user_id: string;
};

type AutomationSettings = {
  business_id: string;
  send_from_local_time: string;
  send_until_local_time: string;
  allow_push: boolean;
};

function renderTemplate(
  template: string,
  variables: Record<string, string | number>,
): string {
  let result = template;
  for (const [key, value] of Object.entries(variables)) {
    const regex = new RegExp(`\\{${key}\\}`, "g");
    result = result.replace(regex, String(value));
  }
  return result;
}

function isWithinSendingWindow(
  settings: AutomationSettings | null,
  timezone = "UTC",
): boolean {
  if (!settings) return true;
  try {
    const formatter = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
    const currentTimeStr = formatter.format(new Date()); // "HH:MM"
    const fromStr = settings.send_from_local_time.slice(0, 5);
    const untilStr = settings.send_until_local_time.slice(0, 5);
    if (fromStr <= untilStr) {
      return currentTimeStr >= fromStr && currentTimeStr <= untilStr;
    }
    // Window crosses local midnight (e.g. 22:00-02:00)
    return currentTimeStr >= fromStr || currentTimeStr <= untilStr;
  } catch {
    return true;
  }
}

// "Today" as a calendar date in the business timezone (YYYY-MM-DD).
// due_date and run_key are local-business-day concepts, not UTC days.
function localDateString(timeZone: string, at: Date = new Date()): string {
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(at);
  } catch {
    return at.toISOString().split("T")[0];
  }
}

// Shift a YYYY-MM-DD date string by whole days (timezone-safe: pure date math).
function shiftDateStr(dateStr: string, days: number): string {
  const date = new Date(`${dateStr}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().split("T")[0];
}

// Offset (ms) between the given timezone and UTC at a given instant.
function timeZoneOffsetMs(at: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).formatToParts(at);
  const values: Record<string, number> = {};
  for (const part of parts) {
    if (part.type !== "literal") values[part.type] = Number(part.value);
  }
  const asUtc = Date.UTC(
    values.year,
    (values.month ?? 1) - 1,
    values.day ?? 1,
    (values.hour ?? 0) % 24,
    values.minute ?? 0,
    values.second ?? 0,
  );
  // Offsets are whole minutes; rounding strips the sub-second drift of `at`.
  return Math.round((asUtc - at.getTime()) / 60000) * 60000;
}

// UTC instant of local midnight for a YYYY-MM-DD date in the given timezone.
function localMidnightUtcIso(dateStr: string, timeZone: string): string {
  try {
    const guess = new Date(`${dateStr}T00:00:00Z`);
    // Two passes keep the result correct across DST transitions.
    let offset = timeZoneOffsetMs(guess, timeZone);
    let utc = new Date(guess.getTime() - offset);
    offset = timeZoneOffsetMs(utc, timeZone);
    utc = new Date(guess.getTime() - offset);
    return utc.toISOString();
  } catch {
    return new Date(`${dateStr}T00:00:00Z`).toISOString();
  }
}

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;

  const methodError = requirePost(request);
  if (methodError) return methodError;

  try {
    requireWorkerSecret(request);
    const admin = serviceClient();

    // 1. Fetch active automation rules with business metadata
    const { data: rules, error: rulesError } = await admin
      .from("automation_rules")
      .select("*")
      .eq("is_active", true);

    if (rulesError) throw rulesError;

    let rulesEvaluated = 0;
    let runsExecuted = 0;
    let runsSkipped = 0;
    const errors: string[] = [];

    for (const rule of (rules ?? []) as AutomationRule[]) {
      rulesEvaluated++;

      // Fetch business and settings
      const { data: business } = await admin
        .from("businesses")
        .select("id,name,currency_code,timezone,owner_user_id")
        .eq("id", rule.business_id)
        .single() as { data: BusinessInfo | null };

      if (!business) continue;

      const { data: settings } = await admin
        .from("business_automation_settings")
        .select("*")
        .eq("business_id", rule.business_id)
        .maybeSingle() as { data: AutomationSettings | null };

      // Check time window
      if (!isWithinSendingWindow(settings, business.timezone)) {
        runsSkipped++;
        continue;
      }

      // All date math uses the business timezone, not UTC: due_date is a
      // local-business-day concept and run_key must be idempotent per local day.
      const todayDate = localDateString(business.timezone);
      let targetDateStr = todayDate;
      if (rule.trigger_type === "before_due") {
        targetDateStr = shiftDateStr(todayDate, rule.offset_days);
      } else if (rule.trigger_type === "after_due") {
        targetDateStr = shiftDateStr(todayDate, -rule.offset_days);
      }

      if (["before_due", "on_due", "after_due"].includes(rule.trigger_type)) {
        // Query candidate debt entries with matching due_date and positive balance
        const { data: candidateDebts, error: debtError } = await admin
          .from("ledger_entries")
          .select(`
            id,
            business_customer_id,
            customer_id,
            amount,
            due_date,
            business_customers (
              id,
              local_display_name,
              customers (
                id,
                user_id
              )
            )
          `)
          .eq("business_id", rule.business_id)
          .eq("entry_type", "debt")
          .eq("due_date", rule.trigger_type === "on_due" ? todayDate : targetDateStr);

        if (debtError) {
          errors.push(`Rule ${rule.id} query error: ${debtError.message}`);
          continue;
        }

        for (const entry of candidateDebts ?? []) {
          const runKey = `${rule.id}:${entry.id}:${todayDate}`;

          // Check if already processed
          const { data: existingRun } = await admin
            .from("automation_runs")
            .select("id,status")
            .eq("run_key", runKey)
            .maybeSingle();

          if (existingRun && existingRun.status === "succeeded") {
            runsSkipped++;
            continue;
          }

          // Check current customer balance to ensure debt is still unpaid
          const { data: balanceRow } = await admin
            .from("business_customer_balances")
            .select("current_balance")
            .eq("business_customer_id", entry.business_customer_id)
            .maybeSingle();

          if (!balanceRow || Number(balanceRow.current_balance) <= 0) {
            runsSkipped++;
            continue;
          }

          // Record run initiation
          const { data: runRecord, error: runInsertError } = await admin
            .from("automation_runs")
            .upsert({
              rule_id: rule.id,
              business_customer_id: entry.business_customer_id,
              ledger_entry_id: entry.id,
              run_key: runKey,
              status: "running",
              attempted_at: new Date().toISOString(),
            }, { onConflict: "run_key" })
            .select("id")
            .single();

          if (runInsertError) {
            errors.push(`Run insert failed for ${runKey}: ${runInsertError.message}`);
            continue;
          }

          try {
            const busCust = entry.business_customers as unknown as {
              local_display_name: string;
              customers: { id: string; user_id: string | null } | null;
            } | null;
            const customerName = busCust?.local_display_name ?? "العميل";
            const targetUserId = busCust?.customers?.user_id;

            const messageBody = renderTemplate(rule.message_template, {
              customer_name: customerName,
              amount: entry.amount,
              currency: business.currency_code,
              due_date: entry.due_date ?? todayDate,
              business_name: business.name,
            });

            // 1. Create reminder record using the actual reminders schema
            //    (sent_by_user_id + message_snapshot are NOT NULL; there is no
            //    ledger_entry_id/title/body). Recorded on behalf of the owner.
            const { error: reminderError } = await admin.from("reminders").insert({
              business_id: rule.business_id,
              business_customer_id: entry.business_customer_id,
              sent_by_user_id: business.owner_user_id,
              channel: rule.channel,
              message_snapshot: messageBody.slice(0, 1000),
              status: targetUserId ? "sent" : "queued",
              sent_at: targetUserId ? new Date().toISOString() : null,
            });
            if (reminderError) throw reminderError;

            // 2. If customer is registered in app, enqueue the notification via
            //    the transactional outbox so push delivery actually happens.
            if (targetUserId) {
              const { error: enqueueError } = await admin.rpc(
                "service_enqueue_notification",
                {
                  p_user_id: targetUserId,
                  p_type: "payment_due",
                  p_title: `تذكير استحقاق من ${business.name}`,
                  p_body: messageBody,
                  p_entity_type: "ledger_entry",
                  p_entity_id: entry.id,
                  p_data: {
                    business_id: rule.business_id,
                    business_customer_id: entry.business_customer_id,
                    ledger_entry_id: entry.id,
                    amount: entry.amount,
                    currency: business.currency_code,
                  },
                },
              );
              if (enqueueError) throw enqueueError;
            }

            // Mark run as succeeded
            await admin
              .from("automation_runs")
              .update({
                status: "succeeded",
                completed_at: new Date().toISOString(),
                result: { messageBody, sentToUser: Boolean(targetUserId) },
              })
              .eq("id", runRecord.id);

            runsExecuted++;
          } catch (execError) {
            const errorMsg = execError instanceof Error ? execError.message : "execution_failed";
            await admin
              .from("automation_runs")
              .update({
                status: "failed",
                completed_at: new Date().toISOString(),
                result: { error: errorMsg },
              })
              .eq("id", runRecord.id);
            errors.push(`Run execution failed for ${runKey}: ${errorMsg}`);
          }
        }
      } else if (rule.trigger_type === "dispute_sla") {
        // Find disputes older than the SLA threshold without resolution.
        // Threshold is anchored to local midnight in the business timezone so
        // evaluation is stable within a local day and aligned with run_key.
        const slaThreshold = localMidnightUtcIso(
          shiftDateStr(todayDate, -rule.offset_days),
          business.timezone,
        );

        // Dispute status lives in the dispute_state table (1:1), not on disputes.
        const { data: candidateDisputes, error: disputeError } = await admin
          .from("disputes")
          .select(`
            id,
            business_id,
            entry_id,
            created_at,
            dispute_state!inner (
              status
            )
          `)
          .eq("business_id", rule.business_id)
          .in("dispute_state.status", ["open", "awaiting_merchant"])
          .lte("created_at", slaThreshold);

        if (disputeError) {
          errors.push(`Rule ${rule.id} dispute query error: ${disputeError.message}`);
          continue;
        }

        for (const dispute of candidateDisputes ?? []) {
          const runKey = `${rule.id}:${dispute.id}:${todayDate}`;

          const { data: existingRun } = await admin
            .from("automation_runs")
            .select("id,status")
            .eq("run_key", runKey)
            .maybeSingle();

          if (existingRun && existingRun.status === "succeeded") {
            runsSkipped++;
            continue;
          }

          const { data: runRecord, error: runInsertError } = await admin
            .from("automation_runs")
            .upsert({
              rule_id: rule.id,
              run_key: runKey,
              status: "running",
              attempted_at: new Date().toISOString(),
            }, { onConflict: "run_key" })
            .select("id")
            .single();

          if (runInsertError) continue;

          try {
            // Disputes are already filtered to this rule's business, so the
            // owner is the business owner fetched above.
            const businessOwner = business.owner_user_id;
            const messageBody = renderTemplate(rule.message_template, {
              business_name: business.name,
              dispute_id: dispute.id.slice(0, 8),
              sla_days: rule.offset_days,
            });

            if (businessOwner) {
              // Enqueue via the transactional outbox so push delivery happens.
              const { error: enqueueError } = await admin.rpc(
                "service_enqueue_notification",
                {
                  p_user_id: businessOwner,
                  p_type: "system",
                  p_title: `تنبيه تأخر الرد على اعتراض - ${business.name}`,
                  p_body: messageBody,
                  p_entity_type: "dispute",
                  p_entity_id: dispute.id,
                  p_data: { dispute_id: dispute.id, business_id: dispute.business_id },
                },
              );
              if (enqueueError) throw enqueueError;
            }

            await admin
              .from("automation_runs")
              .update({
                status: "succeeded",
                completed_at: new Date().toISOString(),
                result: { disputeId: dispute.id, notifiedUser: businessOwner },
              })
              .eq("id", runRecord.id);

            runsExecuted++;
          } catch (execError) {
            const errorMsg = execError instanceof Error ? execError.message : "execution_failed";
            await admin
              .from("automation_runs")
              .update({
                status: "failed",
                completed_at: new Date().toISOString(),
                result: { error: errorMsg },
              })
              .eq("id", runRecord.id);
            errors.push(`Dispute run failed for ${runKey}: ${errorMsg}`);
          }
        }
      }
    }

    return json(request, {
      status: "completed",
      rulesEvaluated,
      runsExecuted,
      runsSkipped,
      errors: errors.length > 0 ? errors : undefined,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    return errorResponse(
      request,
      message === "unauthorized_worker" ? 401 : 500,
      message,
      "Unable to process automation rules.",
    );
  }
});
