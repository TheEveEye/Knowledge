import { isIP } from "node:net";
import { fromNodeHeaders } from "better-auth/node";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Config } from "../config.js";
import type { Authentication } from "./auth.js";

// Enable additional account operations explicitly when their product flows ship.
const authRoutes = new Map([
  ["/api/auth/get-session", "GET"],
  ["/api/auth/list-sessions", "GET"],
  ["/api/auth/sign-out", "POST"],
  ["/api/auth/revoke-session", "POST"],
  ["/api/auth/revoke-sessions", "POST"],
  ["/api/auth/revoke-other-sessions", "POST"],
]);

function authHeaders(request: FastifyRequest, config: Config): Headers {
  const headers = fromNodeHeaders(request.headers);
  // Only the configured Cloudflare deployment trusts this edge-set, single IP.
  // Local and direct development traffic uses the socket IP, never forwarded input.
  const cloudflareIP = request.headers["cf-connecting-ip"];
  const ip = config.auth.trustCloudflare && typeof cloudflareIP === "string" && isIP(cloudflareIP)
    ? cloudflareIP : request.ip;
  headers.set("x-knowledge-client-ip", ip);
  return headers;
}

function forwardHeaders(headers: Headers, reply: FastifyReply) {
  for (const [name, value] of headers) {
    if (!["set-cookie", "content-length", "transfer-encoding", "connection"].includes(name)) reply.header(name, value);
  }
  const cookies = headers.getSetCookie();
  if (cookies.length) reply.header("set-cookie", cookies);
  reply.header("Cache-Control", "no-store");
}

export function registerAccountRoutes(app: FastifyInstance, auth: Authentication, config: Config) {
  app.route({
    method: ["GET", "POST"],
    url: "/api/auth/*",
    bodyLimit: 16_384,
    async handler(request, reply) {
      const path = request.url.split("?")[0] ?? "";
      if (authRoutes.get(path) !== request.method) return reply.code(404).send({ error: "Not found" });
      const response = await auth.handler(new Request(`${config.auth.baseURL}${request.url}`, {
        method: request.method,
        headers: authHeaders(request, config),
        ...(request.body === undefined ? {} : { body: JSON.stringify(request.body) }),
      }));
      forwardHeaders(response.headers, reply);
      return reply.code(response.status).send(response.body ? await response.text() : null);
    },
  });

  app.get("/api/me", {
    schema: {
      response: {
        200: {
          type: "object", additionalProperties: false, required: ["user"],
          properties: {
            user: {
              type: "object", additionalProperties: false,
              required: ["id", "name", "email", "emailVerified", "image", "createdAt"],
              properties: {
                id: { type: "string", format: "uuid" },
                name: { type: "string" },
                email: { type: "string" },
                emailVerified: { type: "boolean" },
                image: { anyOf: [{ type: "string" }, { type: "null" }] },
                createdAt: { type: "string", format: "date-time" },
              },
            },
          },
        },
        401: {
          type: "object", additionalProperties: false, required: ["error"],
          properties: { error: { type: "string", enum: ["Unauthorized"] } },
        },
      },
    },
  }, async (request, reply) => {
    const result = await auth.api.getSession({ headers: authHeaders(request, config), returnHeaders: true });
    forwardHeaders(result.headers, reply);
    if (!result.response) return reply.code(401).send({ error: "Unauthorized" });
    const { user } = result.response;
    return { user: {
      id: user.id, name: user.name, email: user.email, emailVerified: user.emailVerified,
      image: user.image ?? null, createdAt: user.createdAt.toISOString(),
    } };
  });
}
