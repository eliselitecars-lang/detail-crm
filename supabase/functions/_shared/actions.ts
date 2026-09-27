/**
 * Action routing. Each business function exposes several actions on one URL:
 *
 *  - JSON actions: `POST {"action": "refund", ...params}`; `params` (the body
 *    without `action`) is validated by the action's zod schema.
 *  - Raw actions (webhooks with signed bodies, e.g. Twilio form posts):
 *    selected by query string `?action=twilio_inbound`; the handler receives
 *    the untouched Request so it can verify the signature over the raw body.
 *
 * A JSON action may also be selected by `?action=`; if the body names a
 * different action the request is rejected.
 */
import { z } from "zod";
import { HttpError } from "./errors.ts";
import {
  type BodyOptions,
  DEFAULT_MAX_BODY_BYTES,
  type HandlerContext,
  readJson,
  readJsonSized,
  validate,
} from "./http.ts";

export const ACTION_NAME = /^[a-z][a-z0-9_]{0,62}$/;

export interface JsonAction<C> {
  readonly kind: "json";
  readonly input: z.ZodType;
  readonly body?: BodyOptions;
  handle(input: unknown, ctx: C & ActionContext): Promise<unknown> | unknown;
}

export interface RawAction<C> {
  readonly kind: "raw";
  handle(req: Request, ctx: C & ActionContext): Promise<unknown> | unknown;
}

export type Action<C> = JsonAction<C> | RawAction<C>;

export interface ActionContext extends HandlerContext {
  req: Request;
  action: string;
}

/** Defines a JSON action; `input` should usually be a `.strict()` object. */
export function jsonAction<S extends z.ZodType, C = unknown>(
  input: S,
  handle: (input: z.output<S>, ctx: C & ActionContext) => Promise<unknown> | unknown,
  body?: BodyOptions,
): JsonAction<C> {
  return {
    kind: "json",
    input,
    body,
    handle: (value, ctx) => handle(value as z.output<S>, ctx),
  };
}

/** Defines a raw action (reads/verifies the Request itself). */
export function rawAction<C = unknown>(
  handle: (req: Request, ctx: C & ActionContext) => Promise<unknown> | unknown,
): RawAction<C> {
  return { kind: "raw", handle };
}

function unknownAction(): HttpError {
  return new HttpError("unknown_action", "Unknown or missing action.");
}

/**
 * Builds a dispatcher for `createHandler`. `extra` supplies per-request
 * dependencies (clients, env-derived config) merged into each action's ctx.
 */
export function createActionRouter<C = Record<never, never>>(
  actions: Readonly<Record<string, Action<C>>>,
): (req: Request, ctx: HandlerContext, extra?: C) => Promise<unknown> {
  for (const name of Object.keys(actions)) {
    if (!ACTION_NAME.test(name)) throw new Error(`Invalid action name "${name}"`);
  }

  const lookup = (name: string): Action<C> | undefined =>
    Object.hasOwn(actions, name) ? actions[name] : undefined;

  return async (req, handlerCtx, extra) => {
    const fromQuery = new URL(req.url).searchParams.get("action");
    const baseCtx = (action: string) =>
      ({ ...(extra ?? {}), ...handlerCtx, req, action }) as C & ActionContext;

    if (fromQuery !== null) {
      const action = lookup(fromQuery);
      if (!action) throw unknownAction();
      if (action.kind === "raw") return await action.handle(req, baseCtx(fromQuery));
      const body = await readJson(req, action.body);
      const params = splitAction(body, fromQuery);
      return await action.handle(validate(action.input, params), baseCtx(fromQuery));
    }

    // No query action: the JSON body names it. Read with the largest limit any
    // JSON action allows, then enforce the chosen action's own limit.
    const { value: body, bytes } = await readJsonSized(req, {
      maxBytes: largestJsonLimit(actions),
    });
    const name = actionNameOf(body);
    const action = name === null ? undefined : lookup(name);
    if (!action || name === null || action.kind === "raw") throw unknownAction();
    const limit = action.body?.maxBytes ?? DEFAULT_MAX_BODY_BYTES;
    if (bytes > limit) {
      throw new HttpError("payload_too_large", `The request body must be at most ${limit} bytes.`);
    }
    return await action.handle(validate(action.input, splitAction(body, name)), baseCtx(name));
  };
}

function largestJsonLimit<C>(actions: Readonly<Record<string, Action<C>>>): number {
  let max = DEFAULT_MAX_BODY_BYTES;
  for (const action of Object.values(actions)) {
    if (action.kind === "json") max = Math.max(max, action.body?.maxBytes ?? 0);
  }
  return max;
}

function actionNameOf(body: unknown): string | null {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
  const action = (body as Record<string, unknown>).action;
  return typeof action === "string" ? action : null;
}

/** Returns the body without `action`; rejects a body naming another action. */
function splitAction(body: unknown, expected: string): unknown {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new HttpError("validation_failed", "The request body must be a JSON object.", {
      details: { issues: [{ path: "(root)", message: "expected an object" }] },
    });
  }
  const { action, ...params } = body as Record<string, unknown>;
  if (action !== undefined && action !== expected) {
    throw new HttpError("bad_request", "The action in the body does not match the URL.");
  }
  return params;
}
