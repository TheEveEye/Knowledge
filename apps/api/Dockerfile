FROM node:24-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY apps/api/package.json ./apps/api/package.json
RUN npm ci
COPY apps/api ./apps/api
RUN npm run build && npm prune --omit=dev

FROM node:24-bookworm-slim AS runtime
ARG APP_REVISION=development
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000 APP_REVISION=$APP_REVISION
LABEL org.opencontainers.image.source="https://github.com/TheEveEye/Knowledge"
LABEL org.opencontainers.image.revision=$APP_REVISION
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/apps/api/package.json ./apps/api/package.json
COPY --from=build /app/apps/api/dist ./apps/api/dist
COPY --from=build /app/apps/api/drizzle ./apps/api/drizzle
USER node
WORKDIR /app/apps/api
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 CMD ["node", "--input-type=module", "-e", "const r = await fetch('http://127.0.0.1:' + process.env.PORT + '/api/ready', { signal: AbortSignal.timeout(3000) }); process.exit(r.ok ? 0 : 1)"]
CMD ["node", "dist/server.js"]
