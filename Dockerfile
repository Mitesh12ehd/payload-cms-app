# syntax=docker/dockerfile:1.7
FROM node:22.23.4-alpine AS base
# Trust the Amazon RDS CA bundle so sslmode=require can verify the server (used by build, migrate and runtime)
RUN mkdir -p /certs \
  && wget -qO /certs/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
ENV NODE_EXTRA_CA_CERTS=/certs/global-bundle.pem

FROM base AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml* ./
RUN corepack enable pnpm && pnpm install --frozen-lockfile

FROM base AS builder
WORKDIR /app
RUN corepack enable pnpm
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
# Secrets are mounted only for this RUN step - never written to a layer, ENV or image history.
RUN --mount=type=secret,id=database_url \
    --mount=type=secret,id=payload_secret \
    DATABASE_URL="$(cat /run/secrets/database_url)" \
    PAYLOAD_SECRET="$(cat /run/secrets/payload_secret)" \
    pnpm run build

# One-off image used by the pipeline to run `payload migrate` before the rollout.
# (Secrets are NOT baked in; they are injected at `docker run` time.)
FROM builder AS migrator
CMD ["pnpm", "payload", "migrate"]

FROM base AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

RUN addgroup --system --gid 1001 nodejs \
  && adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
RUN mkdir .next && chown nextjs:nodejs .next
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

# Shallow liveness check (does not touch the DB, so a DB blip does not mark every container unhealthy)
HEALTHCHECK --interval=15s --timeout=3s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/health || exit 1

CMD ["node", "server.js"]