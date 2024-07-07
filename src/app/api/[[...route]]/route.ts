import { Hono } from "hono";
import { handle } from "hono/vercel";

import user from "./user";

// Revert to "edge" if planning on running on the edge
export const runtime = "nodejs";

const app = new Hono().basePath("/api");

const routes = app
  .route("/user", user)

export const GET = handle(app);

export type AppType = typeof routes;
