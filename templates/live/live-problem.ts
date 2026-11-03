/**
 * The app's one-line record of a refusal (live problems). Copy this file into
 * the app and call it where the app calls an outside service:
 *
 *   const res = await fetch(url, init);
 *   if (!res.ok) await refused("vision", "plant-photos", res);
 *
 * and, for the app's own caught error, `failed("watering-reminders", error)`.
 *
 * It writes one line to the host's log, in a fixed shape, and nothing else:
 *
 *   sipnship live/1 service=vision feature=plant-photos status=403 reason=SERVICE_DISABLED account=492817306255 count=3
 *
 * The provider's message is never written, because a provider may quote back
 * what the app sent; neither is the request, a prompt or a key. Only the
 * provider's own reason code is read (Google's error detail reason, Stripe's
 * error code, an OpenAI-style error type), and the Google project number from
 * the error's consumer field, digits only. One line a minute per cause: the
 * failures in between are folded into the next line's count. No dependency.
 */

export const LINE_MARK = "sipnship live/1";

/** What a refusal comes down to: names, a status, a reason code, never a message. */
export interface RefusalDetails {
  status: string;
  reason?: string;
  account?: string;
}

/** A refusal as an error, so a caller can say the cause in its own words. Its message names the status only. */
export class Refusal extends Error {
  readonly status: string;
  readonly reason?: string;
  readonly account?: string;
  constructor(details: RefusalDetails, message?: string) {
    super(message ?? `the service answered ${details.status}`);
    this.name = "Refusal";
    this.status = details.status;
    this.reason = details.reason;
    this.account = details.account;
  }
}

const SLUG = /^[a-z0-9][a-z0-9.-]{0,39}$/;
const FEATURE = /[^a-z0-9-]/g;
const REASON = /^[A-Za-z0-9._]{1,40}$/;
const STATUS = /^(\d{3}|timeout|unreachable|error)$/;
const ACCOUNT = /^\d{1,20}$/;
const FOLD_MS = 60_000;

/** The service id as the console lists it, or the address the app called when it is not listed. */
function serviceOf(raw: string): string {
  const s = String(raw).toLowerCase().trim();
  return SLUG.test(s) ? s : "unknown";
}

/** A feature slug cut to its pattern: a to z, digits and hyphens, at most 40. */
export function featureOf(raw: string): string {
  const s = String(raw).toLowerCase().replace(FEATURE, "-").replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, 40);
  return s || "app";
}

/** The provider's reason code, or nothing when it holds anything but letters, digits, dots and underscores. */
export function reasonOf(raw: unknown): string | undefined {
  return typeof raw === "string" && REASON.test(raw) ? raw : undefined;
}

/** The Google project number from a consumer field such as "projects/492817306255", digits only. */
export function accountOf(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const m = /^projects\/(\d+)$/.exec(raw.trim());
  return m && ACCOUNT.test(m[1]!) ? m[1] : undefined;
}

type Json = Record<string, unknown>;
const obj = (v: unknown): Json | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : undefined);

/**
 * The reason and the project number in a provider's refusal body. Google puts
 * them in error.details (an ErrorInfo with a reason and a consumer), Stripe in
 * error.code, OpenAI-style providers in error.code or error.type, Google's
 * sign-in address in a plain error string. error.message is never read.
 */
export function detailsOfBody(body: unknown): { reason?: string; account?: string } {
  const root = obj(body);
  const error = obj(root?.error);
  let reason: string | undefined;
  let account: string | undefined;
  const details = Array.isArray(error?.details) ? (error!.details as unknown[]) : [];
  for (const d of details) {
    const info = obj(d);
    if (!info) continue;
    reason ??= reasonOf(info.reason);
    account ??= accountOf(obj(info.metadata)?.consumer);
  }
  reason ??= reasonOf(error?.code) ?? reasonOf(error?.type) ?? reasonOf(error?.status) ?? reasonOf(root?.error);
  return { reason, account };
}

/** A refused response as details: its status and, when its body is JSON, the reason and the project. The body is read from a copy. */
export async function refusalOf(res: Response): Promise<RefusalDetails> {
  let found: { reason?: string; account?: string } = {};
  try {
    found = detailsOfBody(await res.clone().json());
  } catch {
    // Not JSON, or already read: the status alone says enough.
  }
  return { status: String(res.status), ...found };
}

interface Fold {
  windowStart: number;
  folded: number;
}
const folds = new Map<string, Fold>();

/** The line for one cause, or undefined while a line for it was written in the last minute (the failure is folded into the next one's count). */
export function lineFor(service: string, feature: string, d: RefusalDetails, now: number = Date.now()): string | undefined {
  const status = STATUS.test(d.status) ? d.status : "error";
  const parts = [`service=${serviceOf(service)}`, `feature=${featureOf(feature)}`, `status=${status}`];
  const reason = reasonOf(d.reason);
  if (reason) parts.push(`reason=${reason}`);
  if (d.account && ACCOUNT.test(d.account)) parts.push(`account=${d.account}`);
  const key = parts.join(" ");
  const held = folds.get(key);
  if (held && now - held.windowStart < FOLD_MS) {
    held.folded += 1;
    return undefined;
  }
  const count = (held?.folded ?? 0) + 1;
  folds.set(key, { windowStart: now, folded: 0 });
  return `${LINE_MARK} ${key} count=${count}`;
}

/** Writes the line to the host's log, when one is due. */
export function record(service: string, feature: string, d: RefusalDetails, write: (line: string) => void = console.log, now: number = Date.now()): void {
  const line = lineFor(service, feature, d, now);
  if (line) write(line);
}

/** A failed call to an outside service: reads the reason from the response and writes the line. Returns the details so the caller can say the cause. */
export async function refused(service: string, feature: string, res: Response): Promise<RefusalDetails> {
  const details = await refusalOf(res);
  record(service, feature, details);
  return details;
}

/** The app's own caught error: its kind (the error's name) as the reason, never its message. */
export function failed(feature: string, error: unknown): void {
  const name = error instanceof Error ? error.name : "Error";
  record("app", feature, { status: "error", reason: reasonOf(name) });
}

/** For tests: forget what was written in the last minute. */
export function forgetFolds(): void {
  folds.clear();
}
