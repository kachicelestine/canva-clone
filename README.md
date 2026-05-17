# Canvify

A production-grade, browser-based graphic design platform built on Next.js 14. Users create, edit, and export multi-layer canvas designs with real-time autosave, AI-assisted tooling, an image library, and a Stripe-gated Pro subscription tier.

---

## Table of Contents

1. [System Architecture](#system-architecture)
2. [Tech Stack](#tech-stack)
3. [Database Schema](#database-schema)
4. [API Design](#api-design)
5. [Editor Architecture](#editor-architecture)
6. [Authentication & Authorization](#authentication--authorization)
7. [Subscription & Billing](#subscription--billing)
8. [AI Integration](#ai-integration)
9. [Design Decisions & Trade-offs](#design-decisions--trade-offs)
10. [Local Development](#local-development)
11. [Environment Variables](#environment-variables)
12. [Deployment](#deployment)

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Browser (Client)                           │
│                                                                     │
│  ┌─────────────────┐   ┌───────────────┐   ┌─────────────────────┐ │
│  │  Next.js App    │   │  Fabric.js    │   │  TanStack Query     │ │
│  │  (App Router)   │   │  Canvas       │   │  Cache + Mutations  │ │
│  │  RSC + Client   │   │  (Editor)     │   │  (500ms debounce)   │ │
│  └────────┬────────┘   └───────┬───────┘   └──────────┬──────────┘ │
│           │                   │                        │            │
└───────────┼───────────────────┼────────────────────────┼────────────┘
            │                   │                        │
            ▼                   ▼                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       Next.js Server (Node.js)                      │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    Hono RPC Router  /api/*                    │  │
│  │                                                               │  │
│  │  ┌──────────┐ ┌──────────┐ ┌───────────┐ ┌───────────────┐  │  │
│  │  │ /projects│ │  /users  │ │  /images  │ │/subscriptions │  │  │
│  │  └──────────┘ └──────────┘ └─────┬─────┘ └──────┬────────┘  │  │
│  │                                  │               │            │  │
│  │              ┌───────────────────┘               │            │  │
│  │              │          /ai  ┌────────────────────┘           │  │
│  │              │          ┌───────────────┐                     │  │
│  │              │          │ /generate-img │                     │  │
│  │              │          │ /remove-bg    │                     │  │
│  │              │          └───────────────┘                     │  │
│  └──────────────┼───────────────────────────────────────────────┘  │
│                 │                                                   │
│  ┌──────────────▼───────────────────────────────────────────────┐  │
│  │                NextAuth.js  /api/auth/*                      │  │
│  │         Credentials  │  Google OAuth  │  JWT Sessions        │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                     │
└──────────────────────┬──────────────────────────────────────────────┘
                       │
          ┌────────────┼──────────────────────────────┐
          │            │                              │
          ▼            ▼                              ▼
┌──────────────┐ ┌───────────┐              ┌─────────────────┐
│  Neon        │ │  Stripe   │              │   Replicate     │
│  Serverless  │ │  (Billing)│              │   (AI Models)   │
│  PostgreSQL  │ │  Webhooks │              │   SD3 + Rembg   │
└──────────────┘ └───────────┘              └─────────────────┘
                       │
               ┌───────┴───────┐
               ▼               ▼
        ┌──────────┐   ┌─────────────┐
        │ Unsplash │   │ UploadThing │
        │  Images  │   │  (Storage)  │
        └──────────┘   └─────────────┘
```

### Request Lifecycle

1. Browser loads the Next.js App — RSC pages render on the server with session context.
2. The canvas editor is a client component; Fabric.js owns the entire canvas DOM sub-tree.
3. Every state mutation (draw, type, move) updates Fabric's internal object model.
4. A 500 ms debounced React Query mutation serializes the canvas to JSON and PATCHes `/api/projects/:id`.
5. The Hono handler validates the session, runs a `drizzle.update()`, and returns the updated project.
6. External service calls (Replicate, Unsplash, UploadThing, Stripe) are **always proxied through the server** — no API key is ever sent to the browser.

---

## Tech Stack

| Layer | Technology | Rationale |
|---|---|---|
| Framework | Next.js 14 (App Router) | RSC, nested layouts, file-based routing, edge-ready |
| Language | TypeScript 5 (strict) | End-to-end type safety via Hono RPC inference |
| API Layer | Hono 4 | Lightweight, edge-compatible, type-safe RPC without codegen |
| ORM | Drizzle ORM | SQL-first, zero-overhead types, works with Neon serverless driver |
| Database | Neon Serverless PostgreSQL | Branching, auto-suspend, HTTP driver for edge compat |
| Auth | NextAuth v5 (beta) | Multi-provider, Drizzle adapter, JWT sessions |
| Canvas | Fabric.js 5 | Battle-tested canvas lib with full object model and serialization |
| State — Server | TanStack React Query 5 | Mutations, cache invalidation, pagination, background refetch |
| State — Local | Zustand 4 | Minimal boilerplate for modal orchestration |
| UI Components | shadcn/ui + Radix UI | Accessible primitives, unstyled base, Tailwind integration |
| Styling | Tailwind CSS 3 + CSS Variables | Design token system via HSL vars; dark-mode ready |
| File Upload | UploadThing | Managed S3-backed storage; eliminates custom upload infra |
| Payments | Stripe Subscriptions + Webhooks | PCI-compliant checkout, durable event delivery for billing state |
| AI — Generation | Replicate (Stable Diffusion 3) | Pay-per-prediction, no GPU infra to operate |
| AI — Bg Removal | Replicate (Rembg) | Same billing model; composable with generation |
| Stock Photos | Unsplash API | Royalty-free, curated collections, server-proxied |
| Validation | Zod | Runtime schema enforcement on all API boundaries |
| Notifications | Sonner | Accessible toast primitives |

---

## Database Schema

```
┌──────────────────────────────────────────────────────────────────┐
│  users                                                           │
├─────────────────┬──────────────┬─────────────────────────────── ┤
│  id             │ text (PK)    │ UUID, auto-generated           │
│  name           │ text         │ nullable                       │
│  email          │ text         │ NOT NULL, unique               │
│  emailVerified  │ timestamp    │ nullable                       │
│  image          │ text         │ nullable, profile picture URL  │
│  password       │ text         │ nullable, bcrypt hash          │
└─────────────────┴──────────────┴────────────────────────────────┘
       │ 1                                          │ 1
       │                                           │
       │ ∞                                         │ ∞
┌──────────────────────────────────────┐  ┌───────────────────────────────────────┐
│  projects                            │  │  subscriptions                        │
├───────────────┬────────────┬─────────┤  ├──────────────────┬─────────┬──────── ┤
│  id           │ text (PK)  │ UUID    │  │  id              │ text PK │ UUID    │
│  name         │ text       │ NOT NULL│  │  userId          │ text FK │ CASCADE │
│  userId       │ text (FK)  │ CASCADE │  │  subscriptionId  │ text    │ Stripe  │
│  json         │ text       │ NOT NULL│  │  customerId      │ text    │ Stripe  │
│  height       │ integer    │ NOT NULL│  │  priceId         │ text    │ Stripe  │
│  width        │ integer    │ NOT NULL│  │  status          │ text    │ active… │
│  thumbnailUrl │ text       │ nullable│  │  currentPeriodEnd│ ts      │ renewal │
│  isTemplate   │ boolean    │ nullable│  │  createdAt       │ ts      │         │
│  isPro        │ boolean    │ nullable│  │  updatedAt       │ ts      │         │
│  createdAt    │ timestamp  │         │  └──────────────────┴─────────┴─────────┘
│  updatedAt    │ timestamp  │         │
└───────────────┴────────────┴─────────┘

┌──────────────────────────────────────────────────────────────────┐
│  accounts  (NextAuth — OAuth provider links)                     │
├─────────────────────┬──────────────────────────────────────────  ┤
│  userId             │ text (FK → users.id, CASCADE)              │
│  type               │ "oauth" | "oidc"                           │
│  provider           │ "google" | "github" | …                   │
│  providerAccountId  │ text                                       │
│  access_token       │ text, nullable                             │
│  refresh_token      │ text, nullable                             │
│  expires_at         │ integer, nullable                          │
│  PK                 │ (provider, providerAccountId)              │
└─────────────────────┴──────────────────────────────────────────  ┘

sessions, verificationTokens, authenticators — managed by NextAuth Drizzle adapter
```

### Key Schema Decisions

**`projects.json` as text blob** — The entire Fabric.js canvas state is stored as a serialized JSON string rather than decomposed into relational rows. This avoids the impedance mismatch between a deeply nested canvas object graph and a normalized schema, and makes point-in-time snapshot saves trivial. The trade-off is that the field is opaque to SQL queries (no partial object diffing, no indexed search on canvas content).

**`subscriptions` as a separate table** — Keeps billing data isolated from user PII. Stripe is the system of record; this table is a local cache updated via webhook events, not direct API polling.

---

## API Design

All application endpoints are served through a single Hono application mounted at `/api/[[...route]]`. This catch-all Next.js route delegates to Hono's router, which gives us type-safe RPC inference without a code generation step.

```typescript
// Client usage — fully typed, no hand-written types
const client = hc<AppType>(process.env.NEXT_PUBLIC_APP_URL!);
const res = await client.api.projects.$get({ query: { page: "1" } });
```

### Endpoint Reference

```
Projects
  GET    /api/projects                  Paginated list (cursor: page param)
  POST   /api/projects                  Create project
  GET    /api/projects/templates        Paginated template gallery
  GET    /api/projects/:id              Fetch single project
  PATCH  /api/projects/:id             Update canvas JSON + dimensions
  DELETE /api/projects/:id             Hard delete
  POST   /api/projects/:id/duplicate   Deep clone (new id, new timestamps)

Users
  POST   /api/users                    Register with email + password

Images
  GET    /api/images                   30 random Unsplash images

AI
  POST   /api/ai/generate-image        Stable Diffusion 3 (prompt → URL)
  POST   /api/ai/remove-bg             Rembg (imageUrl → transparent PNG URL)

Subscriptions
  POST   /api/subscriptions/checkout   Create Stripe Checkout Session → redirect URL
  GET    /api/subscriptions/current    Active subscription state for current user
  POST   /api/subscriptions/billing    Stripe Customer Portal session → redirect URL
  POST   /api/subscriptions/webhook    Stripe event ingestion (signature-verified)

Auth (NextAuth)
  *      /api/auth/[...nextauth]       OAuth callbacks, session management

Upload
  *      /api/uploadthing              UploadThing file event handler
```

### Auth Middleware

Every Hono route except the Stripe webhook verifies the session via `@hono/auth-js`. A missing or invalid JWT returns `401` before the handler executes. The webhook route uses Stripe signature verification instead — no session context exists for webhook calls.

---

## Editor Architecture

The canvas editor is the core of the product. It is built as a React Client Component that owns a `<canvas>` DOM node managed entirely by Fabric.js.

```
editor/
├── components/
│   ├── editor.tsx              Top-level orchestrator; owns active tool state
│   ├── navbar.tsx              Project title, export, undo/redo, save indicator
│   ├── toolbar.tsx             Context-sensitive object property controls
│   ├── sidebar.tsx             Left rail — routes to active tool panel
│   ├── footer.tsx              Zoom controls, workspace dimensions
│   └── *-sidebar.tsx           One file per tool panel (15 panels)
│
└── hooks/
    ├── use-editor.ts           Fabric.js wrapper — all canvas operations
    ├── use-history.ts          In-memory JSON snapshot stack (undo/redo)
    ├── use-hotkeys.ts          Keyboard shortcut bindings
    ├── use-clipboard.ts        Object copy/paste via Fabric clone API
    ├── use-canvas-events.ts    Fabric event → React state bridge
    ├── use-auto-resize.ts      ResizeObserver → canvas viewport update
    ├── use-window-events.ts    beforeunload guard for unsaved changes
    └── use-load-state.ts       Hydrates Fabric canvas from project JSON
```

### Data Flow

```
User Interaction
      │
      ▼
Fabric.js Internal Model  ←──────────────── use-editor.ts methods
      │                                     (addShape, changeFill, etc.)
      │  canvas:modified / selection:updated events
      ▼
use-canvas-events.ts  ───► React state update (selectedObjects, etc.)
      │
      ▼
Toolbar / Sidebars re-render with active object properties
      │
      │  Any change also triggers:
      ▼
use-history.ts  ──► push JSON snapshot to in-memory stack
      │
      ▼
editor.tsx (500ms debounce)
      │
      ▼
React Query mutation  ──► PATCH /api/projects/:id  ──► Neon DB
```

### History Implementation

Undo/redo is implemented as an **in-memory array of serialized Fabric JSON snapshots**, not a command/action queue. Each structural change appends to the stack. Undo pops the current state and loads the previous snapshot; redo re-applies the popped state.

Trade-off: Simple to implement and immune to complex action sequencing bugs, but the stack holds complete canvas copies — for a design with dozens of high-res images, each snapshot references those image URLs (not the pixel data), so memory growth is bounded by design complexity, not asset size.

### Autosave

Autosave uses a `lodash.debounce` wrapper around the React Query `updateProject` mutation. The debounce window is **500 ms**. This means:
- Rapid edits (typing, dragging) coalesce into a single write.
- A tab close within 500 ms of the last edit may lose that delta. This is an intentional trade-off: a shorter window increases write amplification; a longer window increases data-loss exposure.

---

## Authentication & Authorization

```
Sign-in flow (credentials)

  Browser ──POST /api/auth/callback/credentials──► NextAuth
                                                       │
                                          Zod validates {email, password}
                                                       │
                                          Drizzle: SELECT user WHERE email=…
                                                       │
                                          bcrypt.compare(password, hash)
                                                       │
                                          JWT minted → Set-Cookie (httpOnly)
                                                       │
  Browser ◄──────────── redirect to dashboard ─────────┘

OAuth flow (Google / GitHub)

  Browser ──► /api/auth/signin/google
                    │
              Redirect to provider
                    │
              Provider callback → NextAuth
                    │
              DrizzleAdapter upserts user + account rows
                    │
              JWT minted → Set-Cookie
                    │
  Browser ◄── redirect to dashboard
```

### Session Strategy

JWT sessions are stored in an `httpOnly` cookie. The token carries `id` (user UUID) only — no roles, no permissions. Each API call re-validates by decoding the JWT; no server-side session table lookup is needed on the hot path.

The Drizzle adapter still manages the `sessions`, `accounts`, and `verificationTokens` tables — these are used by the NextAuth UI flows (magic links, session listing in the portal if enabled) but are not read on every API request.

---

## Subscription & Billing

```
Checkout flow

  User clicks "Upgrade"
        │
  POST /api/subscriptions/checkout
        │
  Stripe creates Checkout Session (mode: subscription)
        │
  Browser redirected to Stripe-hosted checkout page
        │
  User completes payment
        │
  Stripe fires checkout.session.completed webhook
        │
  POST /api/subscriptions/webhook (signature verified)
        │
  Drizzle INSERT into subscriptions table
        │
  User lands on /?success=1 → success modal displayed

Renewal flow

  Stripe fires invoice.payment_succeeded (recurring)
        │
  Webhook handler queries subscriptions WHERE subscriptionId=…
        │
  Drizzle UPDATE status + currentPeriodEnd
```

### Subscription State

The `subscriptions.currentPeriodEnd` column is the source of truth for access control. The `checkIsActive` utility adds a 1-day grace buffer:

```typescript
isActive = currentPeriodEnd.getTime() + DAY_IN_MS > Date.now()
```

This tolerates Stripe webhook delivery latency and clock skew at renewal boundaries without requiring a synchronous Stripe API call on every page load.

### Paywall Enforcement

```typescript
// Client-side gate
const { shouldBlock, triggerPaywall } = usePaywall();
if (shouldBlock) { triggerPaywall(); return; }
```

Pro features also carry the `isPro: true` flag on template rows. The API `/projects/templates` filters by `isPro` based on the caller's subscription status, enforcing server-side access control independent of the client-side paywall hook.

---

## AI Integration

Both AI features are backed by [Replicate](https://replicate.com/) — a managed model inference platform. No GPU infrastructure is required.

| Feature | Model | Input | Output |
|---|---|---|---|
| Image Generation | Stable Diffusion 3 | Text prompt | Image URL (Replicate CDN) |
| Background Removal | Rembg | Image URL | PNG with alpha channel (Replicate CDN) |

The Replicate client runs synchronously — the request waits for the prediction to complete. For long-running generations, this can exceed the default serverless function timeout. Acceptable for an interactive design tool where users expect to wait on AI operations.

Generated image URLs are CDN-hosted by Replicate. The `next.config.mjs` allowlist includes `replicate.delivery` for `next/image` optimization.

---

## Design Decisions & Trade-offs

### 1. Hono over tRPC

**Decision:** Use Hono with its RPC client instead of tRPC.

**Why:** Hono is HTTP-first. Routes are standard `GET`/`POST` endpoints consumable by any HTTP client (curl, mobile, external integrations) without a tRPC adapter. The type-safety story is equivalent — `InferResponseType` and `InferRequestType` give full end-to-end inference. Hono also runs natively on Cloudflare Workers, Deno, and Bun without modification.

**Trade-off:** tRPC's batching, subscriptions (WebSocket), and React integration are more mature. For a CRUD-heavy app with no real-time requirements, Hono's simplicity wins.

---

### 2. Fabric.js canvas state as a serialized JSON blob

**Decision:** Store the entire canvas as `project.json: text` rather than decomposing objects into relational rows.

**Why:** Fabric.js has a first-class `canvas.toJSON()` / `canvas.loadFromJSON()` API. The canvas object graph (nested groups, clip paths, filters, transforms) does not have a natural relational mapping. Decomposing it would require a custom serialization layer with no query-time benefit — canvas content is never searched or aggregated at the database level.

**Trade-off:** The `json` column is opaque. You cannot write SQL to find "all projects that contain a blue rectangle." If search-on-canvas-content becomes a requirement, a secondary index (Postgres full-text or a dedicated search service) would be needed.

---

### 3. In-memory undo/redo stack

**Decision:** Undo/redo history lives only in browser memory, not persisted to the server.

**Why:** Persisting every intermediate edit state would require either a full snapshot per keystroke (high write amplification) or a structured diff/patch format (high implementation complexity). For a design tool where "undo" is a session-scoped operation, in-memory is correct.

**Trade-off:** History is lost on page refresh. If the user refreshes mid-session, undo history resets to the last autosaved checkpoint. This is the same behavior as Figma's undo stack.

---

### 4. 500 ms debounced autosave vs. explicit save

**Decision:** Autosave on every change with a 500 ms debounce; no explicit "Save" button.

**Why:** Eliminates the cognitive overhead of manual saving. Industry standard for collaborative design tools (Figma, Notion, Linear).

**Trade-off:** Generates continuous write traffic. For high-frequency edits (rapid drag), this still produces multiple writes per second. A longer debounce (2–5 s) would reduce writes at the cost of higher data-loss exposure. The 500 ms value is tuned for interactive feel vs. write cost balance.

---

### 5. NextAuth JWT sessions over database sessions

**Decision:** `session: { strategy: "jwt" }` — no server-side session lookup per request.

**Why:** Every API request decodes a local JWT without touching the database. This is critical for Hono route handlers which may scale horizontally — no shared session store required.

**Trade-off:** JWTs cannot be invalidated server-side before they expire. A compromised token is valid until expiry. Mitigated by short token TTL and `httpOnly` cookie storage (XSS-resistant).

---

### 6. Stripe webhooks as the billing source of truth

**Decision:** Subscription state is written exclusively via webhooks, not the checkout redirect.

**Why:** Browser redirects are unreliable — users close tabs, network drops, etc. The `checkout.session.completed` webhook is retried by Stripe for 72 hours with exponential backoff. This guarantees the subscription row is created even if the user never returns to the success URL.

**Trade-off:** There is a window between payment completion and webhook delivery (typically < 2 s, but can be delayed) where the user's UI may not reflect their new subscription. The success modal is shown optimistically via the `?success=1` query param; the actual access gate uses the DB-backed subscription check.

---

### 7. Replicate for AI inference (no self-hosted models)

**Decision:** All AI inference runs on Replicate's managed platform.

**Why:** Zero GPU infrastructure to operate. Cost is strictly pay-per-prediction. Multiple models (SD3, Rembg) share the same API contract.

**Trade-off:** Replicate adds ~1–3 s cold-start latency if the model hasn't run recently. Cannot fine-tune models on user data or run inference offline. Vendor dependency for a core feature. For a product at scale, migrating to a self-hosted inference cluster (e.g., Modal, RunPod, or dedicated GPU instances) would be the next step.

---

### 8. UploadThing over self-managed S3

**Decision:** User file uploads go through UploadThing rather than a direct S3 presigned URL flow.

**Why:** UploadThing handles file validation, virus scanning hooks, CDN delivery, and the presigned URL lifecycle without custom infrastructure. Tailwind plugin integration (`uploadthing/tw`) gives styled upload components out of the box.

**Trade-off:** Additional vendor dependency; pricing is per-GB uploaded. For high-volume uploads, a direct S3 flow with a custom presigned URL endpoint would be more cost-efficient.

---

## Local Development

### Prerequisites

- Node.js 20+ or Bun 1.x
- A Neon account with a PostgreSQL database
- A Stripe account (test mode keys are sufficient)
- Replicate API token
- Unsplash developer account
- UploadThing account
- Google OAuth application (optional, for OAuth login)

### Setup

```bash
# 1. Clone and install
git clone <repo-url>
cd nextjs-canva-clone
bun install          # or npm install

# 2. Configure environment
cp .env.example .env.local
# Fill in all required variables (see below)

# 3. Push database schema
bun run db:push      # drizzle-kit push

# 4. Start dev server
bun run dev
```

The app will be available at `http://localhost:3000`.

### Database Management

```bash
bun run db:push      # Push schema changes to the database
bun run db:studio    # Open Drizzle Studio (visual DB browser)
```

### Stripe Webhook (local)

Use the Stripe CLI to forward webhook events to your local server:

```bash
stripe listen --forward-to localhost:3000/api/subscriptions/webhook
```

The CLI prints a webhook signing secret — use it as `STRIPE_WEBHOOK_SECRET` in your `.env.local`.

---

## Environment Variables

```bash
# ─── Database ────────────────────────────────────────────────────────
DATABASE_URL=postgresql://user:pass@host/db?sslmode=require

# ─── NextAuth ────────────────────────────────────────────────────────
AUTH_SECRET=<random-32-byte-hex>
GOOGLE_ID=<google-oauth-client-id>
GOOGLE_SECRET=<google-oauth-client-secret>

# ─── Stripe ──────────────────────────────────────────────────────────
STRIPE_SECRET_KEY=sk_test_…
STRIPE_WEBHOOK_SECRET=whsec_…
STRIPE_PRICE_ID=price_…

# ─── AI / Replicate ──────────────────────────────────────────────────
REPLICATE_API_TOKEN=r8_…

# ─── Images / Unsplash ───────────────────────────────────────────────
NEXT_PUBLIC_UNSPLASH_ACCESS_KEY=<unsplash-access-key>

# ─── File Upload / UploadThing ───────────────────────────────────────
UPLOADTHING_SECRET=sk_live_…
UPLOADTHING_APP_ID=<app-id>

# ─── App ─────────────────────────────────────────────────────────────
NEXT_PUBLIC_APP_URL=http://localhost:3000
```

---

## Deployment

The application targets **Vercel** (zero-config for Next.js App Router) but runs on any Node.js host.

### Vercel

```bash
vercel deploy --prod
```

Set all environment variables in the Vercel dashboard. Update `NEXT_PUBLIC_APP_URL` to your production domain.

### Docker / Self-hosted

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY . .
RUN npm ci && npm run build

FROM node:20-alpine AS runner
WORKDIR /app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]
```

Enable `output: "standalone"` in `next.config.mjs` for the above Dockerfile.

### Post-deployment checklist

- [ ] `NEXT_PUBLIC_APP_URL` set to production domain
- [ ] Stripe webhook endpoint registered at `https://<domain>/api/subscriptions/webhook`
- [ ] Stripe webhook events enabled: `checkout.session.completed`, `invoice.payment_succeeded`
- [ ] `DATABASE_URL` pointing to production Neon branch
- [ ] Google OAuth redirect URIs updated to include production domain
- [ ] UploadThing callback URL allowlist updated
