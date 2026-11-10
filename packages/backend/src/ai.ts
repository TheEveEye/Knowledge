import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { and, eq, gt, gte, sql } from "drizzle-orm";
import { createRemoteJWKSet, decodeJwt, jwtVerify } from "jose";
import type pg from "pg";
import type { AISelection, JSONObject, JSONValue, Model } from "@knowledge/contracts";
import type { Database } from "./database.js";
import { DomainError, completedOperation, expected, hash, invalidate, jsonArray, jsonObject, mutation, requireValue, stringValue } from "./core.js";
import { aiConnections, aiRequests, jobs, operations, serverState } from "./schema.js";
import { retainAIRejection } from "./ai-diagnostics.js";

type Credentials = { accessToken: string; refreshToken: string; idToken: string; expiresAt: number; scopes: string[] };
export interface AIResult { requestID: string; text: string; output: JSONValue[]; inputTokens: number; outputTokens: number }
function secret(name: string): string | undefined { const file = process.env[name + "_FILE"]; return file ? readFileSync(file, "utf8").trim() : process.env[name]; }
const jwks = createRemoteJWKSet(new URL("https://auth.openai.com/.well-known/jwks.json"), { timeoutDuration: 10_000 });
export class CredentialVault {
  private key() { const key = secret("AI_ENCRYPTION_KEY"); if (!key || !/^[a-f0-9]{64}$/i.test(key)) throw new DomainError("AI_UNCONFIGURED", "AI credential storage is not configured.", 503); return Buffer.from(key, "hex"); }
  seal(value: unknown, binding: string) {
    const iv = randomBytes(12), cipher = createCipheriv("aes-256-gcm", this.key(), iv); cipher.setAAD(Buffer.from(binding));
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
    return ["v1", iv.toString("base64url"), cipher.getAuthTag().toString("base64url"), ciphertext.toString("base64url")].join(".");
  }
  open(value: string, binding: string): Credentials {
    const [version, iv, tag, ciphertext] = value.split(".");
    if (version !== "v1" || !iv || !tag || !ciphertext) throw new DomainError("AI_UNAUTHORIZED", "Reconnect this AI connection.", 401);
    const decipher = createDecipheriv("aes-256-gcm", this.key(), Buffer.from(iv, "base64url"));
    decipher.setAAD(Buffer.from(binding)); decipher.setAuthTag(Buffer.from(tag, "base64url"));
    return JSON.parse(Buffer.concat([decipher.update(Buffer.from(ciphertext, "base64url")), decipher.final()]).toString()) as Credentials;
  }
}
function providerError(status: number, code = "") {
  if (status === 401 || status === 403 || ["invalid_api_key", "authentication_error"].includes(code)) return new DomainError("AI_UNAUTHORIZED", "Reconnect your AI connection or check its permissions.", 401);
  if (status === 429 || code.startsWith("subscription_sharing_usage")) return new DomainError("AI_LIMIT", "The selected AI allowance is unavailable. Retry after its limit resets.", 429);
  if ([400, 404, 422].includes(status) || ["invalid_request_error", "model_not_found", "unsupported_parameter", "context_length_exceeded"].includes(code)) return new DomainError("AI_VALIDATION", "The provider rejected this request. Check the selected model, reasoning, and source size before retrying.", 422);
  return new DomainError("PROVIDER_UNAVAILABLE", "The AI provider is temporarily unavailable.", 503);
}
export class AIService {
  readonly vault = new CredentialVault();
  private discoveryCache: { expires: number; token: string; revoke: string } | null = null;
  private tokenRefreshes = new Map<string, Promise<string>>();
  constructor(readonly db: Database, readonly pool: pg.Pool) {}
  private async endpoints() {
    if (this.discoveryCache && this.discoveryCache.expires > Date.now()) return this.discoveryCache;
    const response = await fetch("https://auth.openai.com/.well-known/openid-configuration", { redirect: "error", signal: AbortSignal.timeout(15_000) });
    if (!response.ok) throw providerError(response.status);
    const value = jsonObject(await response.json());
    const endpoint = (key: string) => { const url = new URL(stringValue(value[key])); if (url.protocol !== "https:" || url.host !== "auth.openai.com" || url.username || url.password || url.hash) throw new DomainError("INVALID_PROVIDER", "The AI provider returned invalid endpoints.", 503); return url.href; };
    if (value.issuer !== "https://auth.openai.com") throw new DomainError("INVALID_PROVIDER", "The AI issuer could not be verified.", 503);
    this.discoveryCache = { expires: Date.now() + 3_600_000, token: endpoint("token_endpoint"), revoke: endpoint("revocation_endpoint") }; return this.discoveryCache;
  }
  async hostID() {
    await this.db.insert(serverState).values({ key: "chatgptHostID", value: "urn:uuid:" + randomUUID() }).onConflictDoNothing();
    return requireValue((await this.db.select().from(serverState).where(eq(serverState.key, "chatgptHostID")))[0]).value;
  }
  async connections(userId: string) {
    return (await this.db.select().from(aiConnections).where(eq(aiConnections.userId, userId))).map(c => {
      let identity: { name: string | null; email: string | null } | null = null;
      if (c.credentials && c.status === "active") {
        try {
          // The identity token was verified before entering the authenticated vault.
          // These claims are display metadata; Knowledge ownership always uses userId.
          const claims = decodeJwt(this.vault.open(c.credentials, userId + ":" + c.id).idToken);
          identity = { name: typeof claims.name === "string" ? claims.name : null, email: typeof claims.email === "string" ? claims.email : null };
        } catch { /* An unreadable identity must not hide the connection's disconnect action. */ }
      }
      return { id: c.id, version: c.version, label: c.label, provider: c.provider, status: c.status, revocationPending: c.status === "disconnected" && !!c.credentials, createdAt: c.createdAt.toISOString(), identity };
    });
  }
  async handoff(userId: string, operationID: string, value: { clientID: string; label: string; accessToken: string; refreshToken: string; idToken: string; expiresAt: number; scopes: string[] }) {
    const input = { action: "handoff", ...value }, previous = await completedOperation(this.db, userId, operationID, input); if (previous) return previous;
    if (process.env.CHATGPT_SELF_HOSTED_ENABLED !== "true") throw new DomainError("CHATGPT_DISABLED", "ChatGPT access is disabled for this deployment.", 403);
    if (!/^oaiapp_[A-Za-z0-9_-]+$/.test(value.clientID) || !value.scopes.includes("chatgpt.tokens.use.direct")) throw new DomainError("INVALID_CONNECTION", "Authorize ChatGPT plan use before connecting.");
    let providerSubject: string;
    try { const verified = await jwtVerify(value.idToken, jwks, { issuer: "https://auth.openai.com", audience: value.clientID, algorithms: ["RS256"] }); providerSubject = requireValue(verified.payload.sub); }
    catch { throw new DomainError("INVALID_CONNECTION", "The ChatGPT identity could not be verified.", 401); }
    // Confirm the access grant is usable; identity alone never enables plan inference.
    await this.fetchModels(value.accessToken, "chatgpt");
    const hostID = await this.hostID();
    return mutation(this.db, userId, operationID, input, async tx => {
      const id = randomUUID();
      await tx.insert(aiConnections).values({ id, userId, clientId: value.clientID, providerSubject, label: value.label, credentials: this.vault.seal(value, userId + ":" + id) });
      await invalidate(tx, userId, "connections", null, 1); return { id, hostID };
    });
  }
  private async locked<T>(id: string, work: () => Promise<T>, wait = false): Promise<T> {
    const started = Date.now();
    for (;;) {
      const client = await this.pool.connect(); let acquired = false;
      try {
        const result = await client.query<{ locked: boolean }>("SELECT pg_try_advisory_lock(hashtextextended($1,0)) AS locked", ["ai:" + id]);
        acquired = result.rows[0]?.locked === true;
        if (acquired) return await work();
      } finally {
        try { if (acquired) await client.query("SELECT pg_advisory_unlock(hashtextextended($1,0))", ["ai:" + id]); }
        finally { client.release(); }
      }
      if (!wait || Date.now() - started >= 60_000) throw new DomainError("AI_BUSY", "The AI connection is updating. Retry shortly.", 429);
      // Never hold a pool connection while waiting for another process to refresh.
      await delay(100);
    }
  }
  private async token(userId: string, selection: AISelection): Promise<string> {
    if (selection.funding === "api") {
      if (selection.connectionID !== null) throw new DomainError("INVALID_FUNDING", "API funding does not use a ChatGPT connection.");
      return requireValue(secret("OPENAI_API_KEY"), "Server API access is not configured.");
    }
    if (process.env.CHATGPT_SELF_HOSTED_ENABLED !== "true") throw new DomainError("CHATGPT_DISABLED", "ChatGPT access is disabled for this deployment.", 403);
    if (!selection.connectionID) throw new DomainError("AI_UNAUTHORIZED", "Choose an AI connection before processing.", 401);
    const id = selection.connectionID;
    const current = requireValue((await this.db.select().from(aiConnections).where(and(eq(aiConnections.userId, userId), eq(aiConnections.id, id))))[0]);
    if (current.status !== "active") throw new DomainError("AI_DISCONNECTED", "This AI connection was disconnected.", 403);
    const existing = this.vault.open(current.credentials, userId + ":" + id);
    if (existing.expiresAt > Date.now() + 60_000) return existing.accessToken;
    const key = userId + ":" + id, pending = this.tokenRefreshes.get(key);
    if (pending) return pending;
    const refreshing = this.locked(id, async () => {
      const row = requireValue((await this.db.select().from(aiConnections).where(and(eq(aiConnections.userId, userId), eq(aiConnections.id, id))))[0]);
      if (row.status !== "active") throw new DomainError("AI_DISCONNECTED", "This AI connection was disconnected.", 403);
      let credentials = this.vault.open(row.credentials, userId + ":" + id);
      if (credentials.expiresAt <= Date.now() + 60_000) {
        const response = await fetch((await this.endpoints()).token, { method: "POST", redirect: "error", signal: AbortSignal.timeout(30_000),
          headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "refresh_token", client_id: row.clientId, refresh_token: credentials.refreshToken, resource: "https://api.openai.com/v1" }) });
        if (!response.ok) throw providerError(response.status);
        const body = jsonObject(await response.json());
        const accessToken = stringValue(body.access_token), refreshToken = stringValue(body.refresh_token) || credentials.refreshToken;
        if (!accessToken || typeof body.expires_in !== "number") throw new DomainError("AI_UNAUTHORIZED", "Reconnect your ChatGPT connection.", 401);
        if (typeof body.id_token === "string") {
          try { const result = await jwtVerify(body.id_token, jwks, { issuer: "https://auth.openai.com", audience: row.clientId, algorithms: ["RS256"] }); if (result.payload.sub !== row.providerSubject) throw new Error(); }
          catch { throw new DomainError("AI_UNAUTHORIZED", "The refreshed ChatGPT identity changed.", 401); }
        }
        credentials = { ...credentials, accessToken, refreshToken, idToken: stringValue(body.id_token) || credentials.idToken, expiresAt: Date.now() + body.expires_in * 1000,
          scopes: typeof body.scope === "string" ? body.scope.split(" ") : credentials.scopes };
        if (!credentials.scopes.includes("chatgpt.tokens.use.direct")) throw new DomainError("AI_UNAUTHORIZED", "Authorize ChatGPT plan usage again.", 403);
        await this.db.update(aiConnections).set({ credentials: this.vault.seal(credentials, userId + ":" + id), updatedAt: new Date() }).where(and(eq(aiConnections.userId, userId), eq(aiConnections.id, id), eq(aiConnections.status, "active")));
      }
      return credentials.accessToken;
    }, true);
    this.tokenRefreshes.set(key, refreshing);
    try { return await refreshing; }
    finally { if (this.tokenRefreshes.get(key) === refreshing) this.tokenRefreshes.delete(key); }
  }
  private async fetchModels(token: string, funding: string): Promise<Model[]> {
    const response = await fetch("https://api.openai.com/v1/models", { headers: { Authorization: "Bearer " + token }, redirect: "error", signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw providerError(response.status);
    const body = jsonObject(await response.json());
    return jsonArray(funding === "chatgpt" ? body.models : body.data).map(jsonObject).filter(m => funding !== "chatgpt" || m.visibility === "list")
      .map(m => ({ id: stringValue(m.slug) || stringValue(m.id), name: stringValue(m.display_name) || stringValue(m.id) || stringValue(m.slug), reasoning: ["automatic", "low", "medium", "high"] }));
  }
  async models(userId: string, selection: AISelection) { return this.fetchModels(await this.token(userId, selection), selection.funding); }
  async disconnect(userId: string, id: string, operationID: string, version: number) {
    return this.locked(id, async () => {
      const input = { action: "disconnect", id, version }, previous = await completedOperation(this.db, userId, operationID, input);
      if (previous && previous.revocationPending !== true) return previous;
      const row = requireValue((await this.db.select().from(aiConnections).where(and(eq(aiConnections.userId, userId), eq(aiConnections.id, id))))[0]);
      const staged = await mutation(this.db, userId, operationID, input, async tx => {
        expected(row.version, version);
        await tx.update(aiConnections).set({ status: "disconnected", version: version + 1, updatedAt: new Date() }).where(and(eq(aiConnections.userId, userId), eq(aiConnections.id, id)));
        await tx.update(jobs).set({ status: "blocked", leaseId: null, leaseExpiresAt: null, error: "The AI connection was disconnected.", version: sql`${jobs.version}+1` }).where(and(eq(jobs.userId, userId), eq(jobs.aiConnectionId, id), sql`${jobs.status} IN ('queued','running','paused')`));
        await tx.update(aiRequests).set({ status: "cancelled" }).where(and(eq(aiRequests.userId, userId), eq(aiRequests.connectionId, id), eq(aiRequests.status, "running")));
        await invalidate(tx, userId, "connections", null, version + 1); return { version: version + 1, revocationPending: true };
      });
      let revoked = !row.credentials;
      if (row.credentials) try {
        const credentials = this.vault.open(row.credentials, userId + ":" + id);
        const response = await fetch((await this.endpoints()).revoke, { method: "POST", redirect: "error", signal: AbortSignal.timeout(20_000), headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ token: credentials.refreshToken, token_type_hint: "refresh_token", client_id: row.clientId }) }); revoked = response.ok;
      } catch { /* Explicitly report unconfirmed remote revocation. */ }
      // Retain encrypted credentials for a later revocation retry when confirmation fails.
      const result = { version: staged.version, revoked };
      await this.db.transaction(async tx => {
        if (revoked) await tx.update(aiConnections).set({ credentials: "" }).where(and(eq(aiConnections.userId, userId), eq(aiConnections.id, id)));
        await tx.update(operations).set({ response: result }).where(and(eq(operations.userId, userId), eq(operations.id, operationID), eq(operations.fingerprint, hash(input))));
      });
      return result;
    });
  }
  private async admit(userId: string, selection: AISelection, kind: string, background: boolean, instructions: string) {
    return this.db.transaction(async tx => {
      if (selection.funding === "chatgpt") {
        const connection = requireValue((await tx.select({ status: aiConnections.status }).from(aiConnections).where(and(eq(aiConnections.userId, userId), eq(aiConnections.id, requireValue(selection.connectionID)))).for("share"))[0]);
        if (connection.status !== "active") throw new DomainError("AI_DISCONNECTED", "This AI connection was disconnected.", 403);
      }
      if (selection.funding === "api") {
        // Serialize allowance accounting without imposing an AI request concurrency cap.
        await tx.execute(sql`SELECT pg_advisory_xact_lock(782115905)`);
        const limit = Number(process.env.AI_API_DAILY_REQUEST_LIMIT ?? 0), start = new Date(); start.setUTCHours(0, 0, 0, 0);
        const used = await tx.select({ id: aiRequests.id }).from(aiRequests).where(and(eq(aiRequests.userId, userId), eq(aiRequests.funding, "api"), gte(aiRequests.createdAt, start)));
        if (!Number.isSafeInteger(limit) || limit <= used.length) throw new DomainError("AI_LIMIT", "Your configured API allowance is unavailable.", 429);
      }
      const id = randomUUID(); await tx.insert(aiRequests).values({ id, userId, connectionId: selection.connectionID, funding: selection.funding, model: selection.model, reasoning: selection.reasoning, policyHash: hash(instructions), kind: (background ? "background:" : "interactive:") + kind, status: "running", leaseExpiresAt: new Date(Date.now() + 60_000) }); return id;
    });
  }
  async respond(userId: string, selection: AISelection, kind: string, instructions: string, input: JSONValue[], schema: JSONObject | null,
    signal: AbortSignal, background = false, delta?: (text: string) => void | Promise<void>, tools?: JSONValue[]): Promise<AIResult> {
    signal.throwIfAborted();
    const token = await this.token(userId, selection);
    signal.throwIfAborted();
    const requestID = await this.admit(userId, selection, kind, background, instructions);
    const controller = new AbortController(), combined = AbortSignal.any([signal, controller.signal, AbortSignal.timeout(240_000)]);
    let heartbeatRunning = false;
    const heartbeat = setInterval(() => {
      if (heartbeatRunning) return; heartbeatRunning = true;
      void this.db.update(aiRequests).set({ leaseExpiresAt: new Date(Date.now() + 60_000) }).where(and(eq(aiRequests.id, requestID), eq(aiRequests.status, "running"), gt(aiRequests.leaseExpiresAt, new Date()))).returning({ id: aiRequests.id })
        .then(rows => { if (!rows.length) controller.abort(); }).catch(() => controller.abort()).finally(() => { heartbeatRunning = false; });
    }, 15_000);
    try {
      const body: JSONObject = { model: selection.model, instructions, input, store: false, stream: true };
      // Only API-funded Recall grading opts into the premium service tier.
      const fastGrading = selection.funding === "api" && (kind === "recall_assessment" || kind === "recall_extra_verify");
      if (fastGrading) body.service_tier = "fast";
      if (selection.reasoning !== "automatic") body.reasoning = { effort: selection.reasoning };
      if (schema) body.text = { format: { type: "json_schema", name: "knowledge_" + kind.replace(/\W/g, "_"), strict: true, schema } };
      if (tools?.length) { body.tools = tools; body.include = ["reasoning.encrypted_content"]; }
      const response = await fetch("https://api.openai.com/v1/responses", { method: "POST", redirect: "error", signal: combined, headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
      if (!response.ok) {
        const rejection = (await response.text()).slice(0, 100_000);
        let code = "";
        try { code = stringValue(jsonObject(jsonObject(JSON.parse(rejection)).error).code); } catch { /* Non-JSON provider response remains available privately. */ }
        await retainAIRejection(userId, requestID, { kind, model: selection.model, reasoning: selection.reasoning,
          status: response.status, providerCode: code, providerRequestID: response.headers.get("x-request-id"),
          policyHash: hash(instructions), rejection, schema });
        process.stderr.write(JSON.stringify({ event: "ai_provider_rejected", kind, requestID, status: response.status }) + "\n");
        if (code === "invalid_json_schema") throw new DomainError("AI_SCHEMA_INVALID", "The server sent an unsupported AI response schema. This needs a server update; your saved work was kept.", 422);
        throw providerError(response.status, code);
      }
      if (!response.body) throw providerError(503);
      let buffer = "", text = "", bytes = 0, completed: JSONObject | null = null;
      const finalized = new Map<number, JSONObject>(), textParts = new Map<string, string>();
      const decoder = new TextDecoder();
      stream: for await (const chunk of response.body) {
        combined.throwIfAborted(); bytes += chunk.byteLength;
        if (bytes > 32 * 1024 * 1024) throw new DomainError("INVALID_AI_RESPONSE", "The AI response exceeded its size limit.");
        buffer = (buffer + decoder.decode(chunk, { stream: true })).replace(/\r\n/g, "\n");
        let boundary: number;
        while ((boundary = buffer.indexOf("\n\n")) >= 0) {
          const frame = buffer.slice(0, boundary); buffer = buffer.slice(boundary + 2);
          const data = frame.split("\n").filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n");
          if (!data || data === "[DONE]") continue;
          const event = jsonObject(JSON.parse(data));
          if (event.type === "response.output_text.delta") { const piece = stringValue(event.delta); text += piece; await delta?.(piece); }
          if (event.type === "response.output_text.done") textParts.set(`${event.output_index}:${event.content_index}`, stringValue(event.text));
          if (event.type === "response.output_item.done") {
            const index = event.output_index, item = jsonObject(event.item);
            if (typeof index !== "number" || !Number.isSafeInteger(index) || index < 0 || index >= 128 || typeof item.type !== "string") throw new DomainError("INVALID_AI_RESPONSE", "The AI returned an invalid finalized item.");
            const previous = finalized.get(index);
            if (previous && JSON.stringify(previous) !== JSON.stringify(item)) throw new DomainError("INVALID_AI_RESPONSE", "The AI returned conflicting finalized items.");
            finalized.set(index, item);
          }
          if (event.type === "response.refusal.delta" || event.type === "response.refusal.done") throw new DomainError("AI_REFUSED", "The AI declined this request. Rephrase your question and try again.");
          if (event.type === "response.completed") { completed = jsonObject(event.response); break stream; }
          if (event.type === "response.failed" || event.type === "error") {
            const error = event.error ? jsonObject(event.error) : event.response ? jsonObject(jsonObject(event.response).error ?? {}) : {};
            throw providerError(503, stringValue(error.code));
          }
          if (event.type === "response.incomplete") throw new DomainError("INCOMPLETE_AI_RESPONSE", "The AI response was incomplete. Retry this step.");
        }
      }
      if (!completed) throw new DomainError("INCOMPLETE_AI_RESPONSE", "The AI stream ended before completion. Retry this step.");
      if (completed.status !== undefined && completed.status !== "completed") throw new DomainError("INCOMPLETE_AI_RESPONSE", "The AI response did not complete.");
      if (fastGrading) process.stderr.write(JSON.stringify({ event: "ai_service_tier", requestID, kind, model: selection.model, requestedTier: "fast", servedTier: completed.service_tier ?? null }) + "\n");
      // Some streams finalize items separately and omit them from response.completed.
      // Preserve tool calls/reasoning as well as text, just as the native adapter does.
      const output = jsonArray(completed.output);
      if (output.length > 128) throw new DomainError("INVALID_AI_RESPONSE", "The AI returned too many output items.");
      const merged = new Map(output.map((item, index) => [index, jsonObject(item)]));
      for (const [index, item] of finalized) {
        const final = merged.get(index);
        if (final && (final.id !== item.id || final.type !== item.type)) throw new DomainError("INVALID_AI_RESPONSE", "The AI completion disagreed with its finalized items.");
        merged.set(index, item);
      }
      const ordered = [...merged].sort(([a], [b]) => a - b);
      if (ordered.some(([index], position) => index !== position)) throw new DomainError("INVALID_AI_RESPONSE", "The AI completion was missing output items.");
      const finalOutput = ordered.map(([, item]) => item);
      const content = finalOutput.filter(item => item.type === "message").flatMap(item => jsonArray(item.content).map(jsonObject));
      if (content.some(part => part.type === "refusal")) throw new DomainError("AI_REFUSED", "The AI declined this request. Rephrase your question and try again.");
      const finalText = content.filter(part => part.type === "output_text").map(part => stringValue(part.text)).join("\n") || [...textParts.values()].join("\n");
      if (finalText) {
        if (finalText.startsWith(text) && finalText.length > text.length) await delta?.(finalText.slice(text.length));
        text = finalText;
      }
      const usage = jsonObject(completed.usage ?? {}), inputTokens = typeof usage.input_tokens === "number" ? usage.input_tokens : 0, outputTokens = typeof usage.output_tokens === "number" ? usage.output_tokens : 0;
      combined.throwIfAborted();
      const saved = await this.db.update(aiRequests).set({ status: "completed", inputTokens, outputTokens }).where(and(eq(aiRequests.id, requestID), eq(aiRequests.status, "running"), gt(aiRequests.leaseExpiresAt, new Date()))).returning({ id: aiRequests.id });
      if (!saved.length) throw new DomainError("AI_DISCONNECTED", "This request was cancelled or lost processing ownership.", 409);
      return { requestID, text, output: finalOutput, inputTokens, outputTokens };
    } catch (error) {
      await this.db.update(aiRequests).set({ status: "failed" }).where(and(eq(aiRequests.id, requestID), eq(aiRequests.status, "running")));
      if (error instanceof DomainError || signal.aborted) throw error;
      throw new DomainError("PROVIDER_UNAVAILABLE", "The AI request was interrupted. Retry to continue.", 503);
    } finally { clearInterval(heartbeat); }
  }
}
