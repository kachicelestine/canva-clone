# Canvify

A production-grade, browser-based graphic design platform. Users create, edit, and export multi-layer canvas designs with real-time autosave, AI-assisted tooling, a searchable image library, and a Stripe-gated Pro subscription tier.

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [Tech Stack & Rationale](#2-tech-stack--rationale)
3. [Database Schema](#3-database-schema)
4. [API Surface](#4-api-surface)
5. [Editor Architecture](#5-editor-architecture)
6. [Auth & Session Design](#6-auth--session-design)
7. [Subscription & Paywall](#7-subscription--paywall)
8. [AI Pipeline](#8-ai-pipeline)
9. [File Storage](#9-file-storage)
10. [Design Decisions & Trade-offs](#10-design-decisions--trade-offs)
11. [Operational Runbook](#11-operational-runbook)
12. [Local Development](#12-local-development)
13. [Docker Deployment](#13-docker-deployment)
14. [Environment Variables](#14-environment-variables)

---

## 1. System Architecture

### High-Level Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Browser (Client)                                │
│                                                                              │
│  ┌──────────────────┐   ┌────────────────────┐   ┌────────────────────────┐ │
│  │  Next.js 14      │   │   Fabric.js 5       │   │  TanStack Query 5      │ │
│  │  App Router      │   │   Canvas Engine     │   │  Cache + Mutations     │ │
│  │  RSC + Client    │   │   (imperative)      │   │  500 ms debounce save  │ │
│  └────────┬─────────┘   └─────────┬──────────┘   └──────────┬─────────────┘ │
│           │                       │                          │               │
└───────────┼───────────────────────┼──────────────────────────┼───────────────┘
            │  HTTP / RPC           │  canvas events           │  PATCH /projects/:id
            ▼                       ▼                          ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                          Next.js Server  (Node.js)                           │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                    Hono RPC Router  /api/*                             │  │
│  │                                                                        │  │
│  │  /projects    /users    /images    /ai              /subscriptions     │  │
│  │   CRUD         me       Unsplash   generate-image   checkout           │  │
│  │   paginate              search     remove-bg        billing-portal     │  │
│  │   templates                                         webhook            │  │
│  └───────────────────────────────┬────────────────────────────────────────┘  │
│                                  │                                            │
│  ┌───────────────────────────────▼────────────────────────────────────────┐  │
│  │               NextAuth v5  /api/auth/*                                 │  │
│  │          Credentials  │  GitHub OAuth  │  Google OAuth  │  JWT         │  │
│  └───────────────────────────────┬────────────────────────────────────────┘  │
│                                  │                                            │
│  ┌───────────────────────────────▼────────────────────────────────────────┐  │
│  │               Drizzle ORM  →  @neondatabase/serverless                 │  │
│  └───────────────────────────────┬────────────────────────────────────────┘  │
└──────────────────────────────────┼─────────────────────────────────────────  ┘
                                   │
          ┌────────────────────────┼───────────────────────────────┐
          │                        │                               │
          ▼                        ▼                               ▼
┌─────────────────┐      ┌─────────────────┐             ┌────────────────────┐
│  Neon           │      │  Stripe         │             │  Replicate         │
│  Serverless     │      │  Checkout       │             │  Stable Diffusion 3│
│  PostgreSQL     │      │  Billing Portal │             │  + Rembg           │
│  (pooled conn.) │      │  Webhooks       │             └────────────────────┘
└─────────────────┘      └─────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
           ┌─────────────────┐         ┌──────────────────┐
           │  Unsplash API   │         │  UploadThing     │
           │  image search   │         │  blob storage    │
           └─────────────────┘         └──────────────────┘
```

### Request Lifecycle

```
Browser                  Next.js Server              Neon DB
  │                           │                         │
  │── GET /editor/[id] ──────▶│ RSC: fetch project      │
  │                           │────── SELECT * ────────▶│
  │                           │◀──── row ───────────────│
  │◀── hydrated HTML ─────────│                         │
  │                           │                         │
  │  [user edits canvas]      │                         │
  │  debounce 500 ms          │                         │
  │── PATCH /api/projects/:id▶│ verifyAuth (JWT)        │
  │                           │────── UPDATE ──────────▶│
  │                           │◀──── updated row ───────│
  │◀── 200 {data} ────────────│                         │
```

---

## 2. Tech Stack & Rationale

| Layer | Choice | Why |
|---|---|---|
| Framework | Next.js 14 App Router | Co-locates RSC data-fetching with UI; file-system routing eliminates boilerplate; Vercel-native but portable via standalone output |
| Canvas | Fabric.js 5 | Most mature browser canvas library; imperative API maps cleanly to undo/redo state machines; v5 is the last stable browser build before v6's ESM-only rewrite |
| API layer | Hono + `@hono/zod-validator` | Type-safe RPC via `hc` client; edge-compatible if needed; Zod validators enforce the contract at the boundary rather than inside handlers |
| ORM | Drizzle ORM | Schema-as-TypeScript eliminates a codegen step; zero runtime overhead; the migration tooling (`drizzle-kit`) is first-class |
| Database | Neon serverless PostgreSQL | Connection pooling built-in; scales to zero in dev; compatible with the standard `pg` wire protocol for local fallback |
| Auth | NextAuth v5 (Auth.js) + Drizzle adapter | Multi-provider out of the box; JWT strategy removes DB round-trips on every authenticated request; Drizzle adapter keeps session data co-located with domain data |
| Payments | Stripe Checkout + Billing Portal | Hosted UI removes PCI scope; webhook-driven state machine is robust against checkout abandonment |
| AI | Replicate (SD3 + Rembg) | Serverless GPU; pay-per-inference; models are swappable without infrastructure changes |
| Images | Unsplash API | 3M+ CC-licensed assets; search API; no CDN cost for delivery |
| File storage | UploadThing | S3-backed; React hooks included; eliminates presigned-URL plumbing |
| State | Zustand (modal state) + TanStack Query (server state) | Zustand for ephemeral UI flags; TanStack Query owns server cache, deduplication, and optimistic updates |
| Package manager | Bun | 10–20× faster installs than npm; compatible lock file; used only in dev/CI — the production runner uses Node |

---

## 3. Database Schema

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  user                                                                       │
│  ─────                                                                      │
│  id          text  PK  (crypto.randomUUID)                                  │
│  name        text                                                           │
│  email       text  NOT NULL                                                 │
│  password    text  (bcrypt hash, NULL for OAuth users)                      │
│  image       text                                                           │
│  emailVerified  timestamp                                                   │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ 1:N
       ┌───────────────────────────┼─────────────────────────────┐
       │                           │                             │
       ▼                           ▼                             ▼
┌─────────────┐          ┌──────────────────┐          ┌──────────────────────┐
│  account    │          │  project         │          │  subscription        │
│  ───────    │          │  ───────         │          │  ────────────        │
│  userId FK  │          │  id     PK       │          │  id         PK       │
│  provider   │◀─ OAuth ▶│  userId FK       │          │  userId     FK       │
│  providerAccountId     │  name            │          │  subscriptionId      │
│  access_token          │  json    text    │          │  customerId          │
│  refresh_token         │  width   int     │          │  priceId             │
│  id_token   │          │  height  int     │          │  status              │
└─────────────┘          │  thumbnailUrl    │          │  currentPeriodEnd    │
                         │  isTemplate bool │          └──────────────────────┘
┌─────────────┐          │  isPro      bool │
│  session    │          │  createdAt       │
│  ─────────  │          │  updatedAt       │
│  sessionToken PK       └──────────────────┘
│  userId FK  │
│  expires    │
└─────────────┘
```

**Key design notes:**

- `project.json` stores the full serialised Fabric.js canvas state as text. This is intentionally schemaless — the canvas object graph is complex and deeply nested; normalising it into relational rows buys nothing and introduces a costly transformation on every save/load.
- `project.isTemplate` and `project.isPro` are flag columns on the same table. Templates are seeded rows owned by a system user; `isPro` gates template access behind the paywall.
- `subscription.status` mirrors Stripe's subscription status string (`active`, `trialing`, `past_due`, `canceled`). The canonical source of truth is always Stripe; the local row is a cache updated by webhooks.

---

## 4. API Surface

All routes live under `/api` and are served by a single Hono app mounted via Next.js catch-all route `app/api/[[...route]]/route.ts`. Authentication is enforced per-route with `verifyAuth()` from `@hono/auth-js`.

### Projects

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/api/projects` | ✓ | Paginated list of the caller's projects (`page`, `limit` query params) |
| `POST` | `/api/projects` | ✓ | Create a new blank project |
| `GET` | `/api/projects/:id` | ✓ | Fetch a single project (ownership-checked) |
| `PATCH` | `/api/projects/:id` | ✓ | Partial update (name, json, dimensions, thumbnail) |
| `DELETE` | `/api/projects/:id` | ✓ | Hard delete (ownership-checked) |
| `POST` | `/api/projects/:id/duplicate` | ✓ | Deep-clone a project |
| `GET` | `/api/projects/templates` | ✓ | Paginated template gallery |

### Images

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/api/images` | ✓ | Proxy Unsplash search (prevents key exposure to the client) |

### AI

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/api/ai/generate-image` | ✓ + Pro | Text-to-image via Replicate SD3 |
| `POST` | `/api/ai/remove-bg` | ✓ + Pro | Background removal via Replicate Rembg |

### Subscriptions

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/api/subscriptions/current` | ✓ | Current subscription status |
| `POST` | `/api/subscriptions/checkout` | ✓ | Create a Stripe Checkout session |
| `POST` | `/api/subscriptions/billing` | ✓ | Create a Stripe Billing Portal session |
| `POST` | `/api/subscriptions/webhook` | — | Stripe webhook receiver (signature-verified) |

### Users

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/api/users/me` | ✓ | Authenticated user profile |

---

## 5. Editor Architecture

The editor is the most complex subsystem. It is built around Fabric.js operating as a managed imperative object, wrapped in React hooks.

```
┌────────────────────────────────────────────────────────────┐
│  <Editor />  (client component)                            │
│                                                            │
│  useEditor()   ←─── the central hook, returns Editor API  │
│     │                                                      │
│     ├── useHistory()      undo/redo stack (JSON snapshots) │
│     ├── useAutoResize()   keeps canvas fit to viewport     │
│     ├── useCanvasEvents() Fabric event → React state sync  │
│     ├── useHotkeys()      Ctrl+Z, Ctrl+C, Delete, …        │
│     ├── useClipboard()    copy/paste object graph          │
│     ├── useLoadState()    hydrates canvas from DB JSON     │
│     └── useWindowEvents() beforeunload dirty-check         │
│                                                            │
│  Sidebar panels (tool-specific):                           │
│    ShapeSidebar  TextSidebar  ImageSidebar  AiSidebar      │
│    FillColorSidebar  StrokeColorSidebar  FilterSidebar      │
│    DrawSidebar  OpacitySidebar  FontSidebar  TemplateSidebar│
│                                                            │
│  Toolbar  →  context-sensitive controls for selection      │
│  Footer   →  zoom in/out, fit-to-screen                    │
└────────────────────────────────────────────────────────────┘
```

### Autosave flow

```
canvas:object:modified
        │
        ▼
  useCanvasEvents → marks dirty, calls save()
        │
        ▼
  save() [use-history.ts]
    JSON.stringify(canvas.toJSON(JSON_KEYS))
        │
        ▼
  useAutoSave (debounced 500 ms)
        │
        ▼
  PATCH /api/projects/:id   { json, updatedAt }
        │
        ▼
  TanStack Query mutation → optimistic cache update
```

### Undo / redo

History is maintained as an in-memory array of serialised canvas snapshots. On undo, the previous snapshot is loaded back via `canvas.loadFromJSON`. This is O(n) in canvas complexity but avoids the need for a separate command pattern — acceptable at the object counts typical of a design canvas.

---

## 6. Auth & Session Design

```
Sign-in flow (Credentials)              Sign-in flow (OAuth)
─────────────────────────               ──────────────────────
Browser → POST /api/auth/callback       Browser → GET /api/auth/signin/github
  email + password                        redirect to provider
  │                                       provider callback → /api/auth/callback
  ▼                                       │
bcrypt.compare(password, hash)            ▼
  │                                     DrizzleAdapter.linkAccount()
  ▼                                       upserts user + account rows
NextAuth issues signed JWT                NextAuth issues signed JWT
  (HS256, AUTH_SECRET)                    │
  │                                       ▼
  ▼                                     Set-Cookie: next-auth.session-token
Set-Cookie: next-auth.session-token     (httpOnly, Secure, SameSite=Lax)
(httpOnly, Secure, SameSite=Lax)
```

**Why JWT strategy, not database sessions?**

Database sessions require a `SELECT` on every authenticated request. With Neon serverless, each connection may cold-start a compute node. JWT validation is pure CPU — zero DB round-trips for the hot path. The trade-off is that revocation requires either a short JWT TTL or a token blocklist (not currently implemented).

**OAuth account linking**

The Drizzle adapter stores OAuth accounts in the `account` table keyed on `(provider, providerAccountId)`. A user who signs in with Google and then with credentials sharing the same email gets two separate `user` rows unless explicit account merging is implemented. This is a known gap — see [§10](#10-design-decisions--trade-offs).

---

## 7. Subscription & Paywall

### State machine

```
                    ┌──────────────┐
         checkout   │              │  invoice.payment_succeeded
         completed  │   active     │◀─────────────────────────┐
       ┌───────────▶│              │                           │
       │            └──────┬───────┘                           │
       │                   │  cancellation /                   │
       │                   │  payment failure                  │
       │                   ▼                                   │
  [no row]          ┌──────────────┐                    ┌──────┴──────┐
       │            │  past_due /  │                    │   Stripe    │
       │            │  canceled    │                    │   Billing   │
       │            └──────────────┘                    │   Portal    │
       │                                                └─────────────┘
       │
       └── POST /api/subscriptions/checkout
               → stripe.checkout.sessions.create()
               → redirect to Stripe hosted page
```

**Webhook reliability:** Stripe retries webhooks for up to 3 days with exponential backoff. The handler is idempotent — `INSERT` on `checkout.session.completed` and `UPDATE` on `invoice.payment_succeeded` both use the Stripe subscription ID as the natural key.

**Paywall enforcement:** The `usePaywall` hook checks `subscription.active` on the client. AI endpoints (`/api/ai/*`) re-check on the server by calling `checkIsActive(subscription)` before proxying to Replicate. Client-side gating is UX; server-side gating is security.

---

## 8. AI Pipeline

```
Client                      Next.js Server              Replicate
  │                               │                         │
  │── POST /api/ai/generate-image▶│ verifyAuth + Pro check  │
  │   { prompt }                  │                         │
  │                               │── POST /predictions ───▶│
  │                               │   model: stability-ai/  │
  │                               │   stable-diffusion-3    │
  │                               │   (sync, await output)  │
  │                               │◀── { output: [url] } ───│
  │◀── 200 { data: imageUrl } ────│                         │

  │── POST /api/ai/remove-bg ────▶│ verifyAuth + Pro check  │
  │   { image }                   │                         │
  │                               │── POST /predictions ───▶│
  │                               │   model: cjwbw/rembg    │
  │                               │◀── { output: url } ─────│
  │◀── 200 { data: imageUrl } ────│                         │
```

Replicate predictions are awaited synchronously (polling handled by the SDK). This means the server-side handler holds an open HTTP connection for the duration of inference — typically 5–15 s for SD3 and 2–5 s for Rembg. This works within Vercel's 60 s serverless function limit and Next.js standalone's Node.js process model.

---

## 9. File Storage

UploadThing acts as an S3-compatible blob store with a React upload hook. The upload core (`src/app/api/uploadthing/core.ts`) defines the file router — accepted MIME types, size limits, and auth callback. The resulting `utfs.io` CDN URLs are stored on `project.thumbnailUrl` and referenced directly in `<Image>` tags (whitelisted in `next.config.mjs`).

---

## 10. Design Decisions & Trade-offs

### 10.1 Canvas state serialised as opaque JSON blob

**Decision:** `project.json` stores the raw Fabric.js `toJSON()` output as a text column.

**Rationale:** The Fabric object graph contains 40+ fields per object (transforms, fill, stroke, shadow, clipPath, filters, etc.). Normalising this into relational rows would require a polymorphic object table and a recursive join on every load — far more complexity for no query benefit.

**Trade-off:** You lose the ability to run any SQL analytics over canvas content. Full-text search across canvas text objects is impossible without post-processing. Accepting this because the product is not search-centric.

**Risk:** If Fabric.js changes its serialisation format between major versions, stored JSON becomes incompatible. Mitigation: pin `fabric` to `5.3.0-browser` and run a migration script if upgrading.

---

### 10.2 Hono on top of Next.js instead of native Route Handlers

**Decision:** All API logic lives in a single Hono app, mounted via a Next.js catch-all route.

**Rationale:** Hono's `hc` typed client lets the frontend call API methods with full TypeScript inference — no OpenAPI codegen required. Route-level middleware (`verifyAuth`, `zValidator`) is composable and tested once. Native Route Handlers would require duplicating middleware on every file.

**Trade-off:** The monolithic Hono app is a single module boundary. Tree-shaking is limited — every route handler is loaded even when only one is needed. At the current scale (< 20 routes) this is immaterial. If the API surface grows to 200+ routes, splitting into multiple catch-all segments becomes worthwhile.

---

### 10.3 JWT sessions with no revocation

**Decision:** NextAuth is configured with `strategy: "jwt"`. Sessions are validated purely by signature, not by a database lookup.

**Rationale:** Eliminates a DB round-trip on every authenticated request. Critical when Neon serverless can add 50–200 ms of connection latency on cold starts.

**Trade-off:** A compromised JWT is valid until its expiry. There is no session table to delete from. Acceptable for the current threat model (self-service consumer app, no PII beyond email). If the product ever handles sensitive data, add a Redis-backed token blocklist or switch to database sessions on a persistent connection pool.

---

### 10.4 Neon serverless PostgreSQL (no replica)

**Decision:** Single Neon branch with the pooled connection string.

**Rationale:** Neon's serverless driver handles connection pooling transparently. Auto-scaling compute eliminates capacity planning for low-to-medium traffic.

**Trade-off:** Neon's free tier has a 500 MB storage limit and compute-hours cap. Read-heavy production traffic should add a read replica or a caching layer (Redis / Upstash) in front of project queries. Also: Neon's serverless driver uses WebSockets, which means it cannot run inside an edge runtime — the Hono router is explicitly set to `runtime = "nodejs"`.

---

### 10.5 Replicate for AI inference (synchronous polling)

**Decision:** AI endpoints await Replicate predictions synchronously before responding to the client.

**Rationale:** Simplest implementation. No queue, no webhook callback URL, no client-side polling loop.

**Trade-off:** Server-side handler holds an open connection for 5–15 s. This blocks the Node.js event loop thread only minimally (the SDK polls with async `await`) but does tie up a serverless function invocation. At scale, the correct architecture is: return a `predictionId` immediately, and have the client poll `GET /api/ai/status/:id`. Not worth the complexity at current usage levels.

---

### 10.6 Monorepo structure (single Next.js app)

**Decision:** All concerns — auth, editor, subscriptions, AI — live in one Next.js application with feature-folder organisation (`src/features/*`).

**Rationale:** Zero inter-service network overhead. A single deploy unit. Type-sharing is trivial because everything is TypeScript in the same module graph.

**Trade-off:** A single large deploy unit; all features scale together. If AI inference usage diverges significantly from dashboard traffic, a separate service would allow independent scaling. The current organisation makes extraction straightforward — each `features/` folder is already a bounded context with its own API hooks, components, and types.

---

### 10.7 No test suite

**Decision:** No unit, integration, or end-to-end tests are included.

**Trade-off:** This is the most significant quality gap. The editor's `use-editor.ts` hook contains the bulk of business logic and has no test coverage. Priority for the next engineering cycle:
1. Integration tests for the Hono API routes against a Neon branch (not mocks — see lessons from real-world regressions caused by mock drift).
2. Unit tests for `checkIsActive` and the history/undo state machine.
3. Playwright e2e for the critical path: sign-in → create project → edit → export.

---

## 11. Operational Runbook

### Stripe webhook local testing

```bash
# Install the Stripe CLI, then:
stripe listen --forward-to http://localhost:3000/api/subscriptions/webhook
# Copy the printed webhook signing secret into STRIPE_WEBHOOK_SECRET
```

### Database migrations

```bash
# Generate migration SQL from schema changes:
bun run db:generate

# Apply migrations to the target database:
bun run db:migrate

# Inspect data via Drizzle Studio:
bun run db:studio
```

Migrations run against whichever `DATABASE_URL` is in scope. In CI, point at a Neon branch, not the production database.

### Rotating AUTH_SECRET

1. Generate a new secret: `openssl rand -base64 32`
2. Update the environment variable in production.
3. All existing JWT sessions are immediately invalidated — users are signed out. Plan for a maintenance window or implement a grace-period dual-secret validation if zero-downtime rotation is required.

### Scaling beyond a single Node process

The application stores no local state — canvas state is in Neon, session state is in the JWT, file state is in UploadThing. Any number of replicas can run behind a load balancer with sticky-session routing disabled.

```
            ┌──────────────┐
            │  Load Balancer│  (e.g. nginx, Cloudflare)
            └──────┬───────┘
         ┌─────────┴─────────┐
         ▼                   ▼
  ┌─────────────┐   ┌─────────────┐
  │  Canvify    │   │  Canvify    │   ← stateless; share nothing
  │  replica 1  │   │  replica 2  │
  └──────┬──────┘   └──────┬──────┘
         └────────┬─────────┘
                  ▼
           ┌─────────────┐
           │  Neon DB    │   ← single source of truth
           └─────────────┘
```

---

## 12. Local Development

### Prerequisites

- **Bun** ≥ 1.1 — `curl -fsSL https://bun.sh/install | bash`
- **Node.js** ≥ 20 (used by some Drizzle tooling)
- A [Neon](https://neon.tech) project with the connection string
- A [Stripe](https://stripe.com) account with a test Price ID
- Optional: Replicate, Unsplash, and UploadThing accounts for AI / image features

### Setup

```bash
# 1. Clone
git clone <repo-url>
cd canvify

# 2. Install dependencies
bun install

# 3. Configure environment
cp .env.example .env.local
# Fill every value in .env.local

# 4. Push schema to the database (first time only)
bun run db:generate
bun run db:migrate

# 5. Start the dev server
bun run dev
# → http://localhost:3000
```

### Stripe webhook (local)

```bash
# In a separate terminal:
stripe listen --forward-to http://localhost:3000/api/subscriptions/webhook
```

Copy the `whsec_...` secret from the Stripe CLI output into `STRIPE_WEBHOOK_SECRET` in `.env.local`, then restart the dev server.

---

## 13. Docker Deployment

### Single-image build

The project uses a three-stage Dockerfile:

| Stage | Base | Purpose |
|---|---|---|
| `deps` | `oven/bun:1.1-alpine` | Install all dependencies from `bun.lockb` |
| `builder` | `oven/bun:1.1-alpine` | Run `next build` with standalone output |
| `runner` | `node:20-alpine` | Minimal production image — only the standalone bundle |

The `output: "standalone"` setting in `next.config.mjs` instructs Next.js to emit a self-contained `server.js` with a pruned `node_modules` — the final image is typically **< 200 MB** vs. > 1 GB for a naive copy of `node_modules`.

```
Image size comparison
──────────────────────
Naive (copy node_modules):   ~1.1 GB
Standalone (this Dockerfile): ~180 MB
```

### Build & run

```bash
# Build image
docker build \
  --build-arg NEXT_PUBLIC_APP_URL=https://canvify.example.com \
  -t canvify:latest .

# Run (pass secrets via environment)
docker run -p 3000:3000 \
  --env-file .env.local \
  canvify:latest
```

### Docker Compose (local)

```bash
# Start the application container
docker compose up --build

# Stop and remove containers
docker compose down
```

`docker-compose.yml` reads all secrets from `.env.local` via the `${VAR}` interpolation syntax — no secrets are hardcoded in the compose file.

### Database migrations in containers

Migrations are **not** run automatically on container start. Run them as a one-off job before deploying a new schema version:

```bash
docker run --rm \
  --env DATABASE_URL="$DATABASE_URL" \
  canvify:latest \
  node -e "require('./migrate.js')"
```

Or, with Bun available in a separate migration image:

```bash
docker run --rm \
  --env DATABASE_URL="$DATABASE_URL" \
  oven/bun:1.1-alpine \
  sh -c "bun install && bun run db:migrate"
```

### Production checklist

- [ ] `NEXT_PUBLIC_APP_URL` build arg set to the real public URL
- [ ] `AUTH_SECRET` is a fresh 32-byte random value (not the dev placeholder)
- [ ] Stripe is in **live mode** with a live `STRIPE_PRICE_ID` and `STRIPE_WEBHOOK_SECRET`
- [ ] Neon is pointed at the production branch (not the dev branch)
- [ ] Health check endpoint responding (`GET /api/health` — add a trivial 200 handler if not present)
- [ ] TLS terminated at the load balancer or reverse proxy (never inside the container)
- [ ] Log aggregation (stdout/stderr) piped to your observability platform

---

## 14. Environment Variables

| Variable | Required | Description |
|---|---|---|
| `NEXT_PUBLIC_APP_URL` | ✓ | Canonical public URL — no trailing slash. Used by Stripe redirects and NextAuth callbacks |
| `DATABASE_URL` | ✓ | Neon pooled connection string |
| `AUTH_SECRET` | ✓ | 32-byte random secret for JWT signing. Generate: `openssl rand -base64 32` |
| `AUTH_GITHUB_ID` | ✓ | GitHub OAuth App client ID |
| `AUTH_GITHUB_SECRET` | ✓ | GitHub OAuth App client secret |
| `AUTH_GOOGLE_ID` | ✓ | Google OAuth 2.0 client ID |
| `AUTH_GOOGLE_SECRET` | ✓ | Google OAuth 2.0 client secret |
| `STRIPE_SECRET_KEY` | ✓ | Stripe secret key (`sk_live_*` in production) |
| `STRIPE_WEBHOOK_SECRET` | ✓ | Stripe webhook signing secret (`whsec_*`) |
| `STRIPE_PRICE_ID` | ✓ | Price ID of the Pro subscription plan |
| `REPLICATE_API_TOKEN` | AI features | Replicate API token (`r8_*`) |
| `UNSPLASH_ACCESS_KEY` | Image search | Unsplash API access key |
| `UPLOADTHING_SECRET` | File upload | UploadThing secret key |
| `UPLOADTHING_APP_ID` | File upload | UploadThing application ID |
