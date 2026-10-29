import { createHmac, randomInt, randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { Resend } from "resend";
import { eq } from "drizzle-orm";
import type { Config } from "../config.js";
import type { Database } from "../db/client.js";
import { emailDeliveryLimit } from "../db/schema.js";

export class EmailLimitError extends Error {
  constructor(readonly retryAfter: number) { super("Email request limit reached"); }
}

export async function reserveEmailDelivery(db: Database, config: Config, email: string) {
  const now = new Date();
  const dayStart = new Date(now);
  dayStart.setUTCHours(0, 0, 0, 0);
  const recipient = createHmac("sha256", config.auth.secret).update(`email-limit:${email}`).digest("hex");
  await db.transaction(async (tx) => {
    // Acquire in the same order for all requests. Row locks coordinate replicas.
    for (const limit of [
      { key: "global", start: dayStart, duration: 86_400_000, maximum: config.email.dailyLimit, cooldown: 0 },
      { key: `recipient:${recipient}`, start: now, duration: 3_600_000, maximum: 5, cooldown: 60_000 },
    ]) {
      await tx.insert(emailDeliveryLimit).values({
        key: limit.key, windowStart: limit.start, nextAllowedAt: now, count: 0,
      }).onConflictDoNothing();
      const [row] = await tx.select().from(emailDeliveryLimit).where(eq(emailDeliveryLimit.key, limit.key)).for("update");
      if (!row) throw new Error("Email delivery budget unavailable");
      const expired = now.getTime() >= row.windowStart.getTime() + limit.duration;
      const count = expired ? 0 : row.count;
      const start = expired ? limit.start : row.windowStart;
      const retryAt = !expired && count >= limit.maximum
        ? start.getTime() + limit.duration : row.nextAllowedAt.getTime();
      if (retryAt > now.getTime()) throw new EmailLimitError(Math.ceil((retryAt - now.getTime()) / 1000));
      await tx.update(emailDeliveryLimit).set({
        count: count + 1, windowStart: start, nextAllowedAt: new Date(now.getTime() + limit.cooldown),
      }).where(eq(emailDeliveryLimit.key, limit.key));
    }
  });
}

export async function sendAccountCode(config: Config, email: string, otp: string, purpose: "email-verification" | "forget-password") {
  if (!config.email.enabled || !config.email.apiKey) throw new Error("Account email unavailable");
  const resend = new Resend(config.email.apiKey);
  const idempotencyKey = `knowledge-${purpose}/${randomUUID()}`;
  const deadline = Date.now() + 18_000;
  if (!/^[0-9]{6}$/.test(otp)) throw new Error("Invalid account code");
  const title = purpose === "email-verification" ? "Verify your Knowledge email" : "Set or reset your Knowledge password";
  const instruction = purpose === "email-verification"
    ? "Enter this code in Knowledge to verify your email address."
    : "Enter this code in Knowledge to set or reset your password. Never share this code.";
  const expiry = "This code expires in five minutes. If you did not request it, you can ignore this email.";
  const payload = {
    from: `Knowledge <${config.email.from}>`, to: [email], subject: title,
    text: `${title}\n\n${instruction}\n\n${otp}\n\n${expiry}`,
    html: `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${title}</title></head><body style="font-family:system-ui,sans-serif;color:#202124;background:#ffffff;padding:24px"><h1>${title}</h1><p>${instruction}</p><p style="font-size:32px;letter-spacing:6px;font-weight:bold">${otp}</p><p>${expiry}</p></body></html>`,
  };
  for (let attempt = 0; attempt < 3; attempt++) {
    // Every retry uses the same code, content, and idempotency key.
    const result = await resend.emails.send(payload, {
      idempotencyKey, signal: AbortSignal.timeout(Math.max(1, Math.min(5000, deadline - Date.now()))),
    });
    if (!result.error && result.data?.id) return result.data.id;
    const status = result.error?.statusCode;
    const retryable = status === null || status === 429 || (typeof status === "number" && status >= 500);
    if (!retryable || attempt === 2) break;
    const retryHeader = result.headers?.["retry-after"];
    let retryAfter = 0;
    if (retryHeader) {
      const seconds = Number(retryHeader);
      retryAfter = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(retryHeader) - Date.now();
      if (!Number.isFinite(retryAfter)) retryAfter = 0;
    }
    const wait = Math.max(1000 * 2 ** attempt + randomInt(0, 200), retryAfter);
    // A longer server cooldown is respected by ending this attempt rather than
    // retrying early or exceeding the native client's request timeout.
    if (Date.now() + wait + 5000 > deadline) break;
    await delay(wait);
  }
  // Provider error objects can contain recipients. Never log or return them.
  throw new Error("Email delivery failed");
}
