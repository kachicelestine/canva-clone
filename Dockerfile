# ── Stage 1: install dependencies ────────────────────────────────────────────
FROM oven/bun:1.1-alpine AS deps

WORKDIR /app

COPY package.json bun.lockb* ./
RUN bun install --frozen-lockfile

# ── Stage 2: build ────────────────────────────────────────────────────────────
FROM oven/bun:1.1-alpine AS builder

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Build-time env stubs — real values must be injected at runtime.
# NEXT_PUBLIC_* vars are baked into the client bundle at build time,
# so pass genuine values here for production builds.
ARG NEXT_PUBLIC_APP_URL=http://localhost:3000

ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production

RUN bun run build

# ── Stage 3: production runner ────────────────────────────────────────────────
# The Next.js standalone output is a self-contained Node server; we switch to
# the official Node image for a minimal, well-audited production base.
FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

RUN addgroup --system --gid 1001 nodejs && \
    adduser  --system --uid 1001 nextjs

# Static assets
COPY --from=builder /app/public ./public

# Standalone bundle (includes a minimal node_modules subset)
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static    ./.next/static

USER nextjs

EXPOSE 3000

ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

CMD ["node", "server.js"]
