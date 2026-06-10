import type { Context } from 'hono'
import type { z } from 'zod'

export type ParseResult<T> =
  | { ok: true; data: T }
  | { ok: false; message: string; issues?: z.ZodIssue[] }

export function parseSchema<T>(schema: z.ZodType<T>, data: unknown): ParseResult<T> {
  const result = schema.safeParse(data)
  if (result.success) {
    return { ok: true, data: result.data }
  }
  const message = result.error.issues
    .map((i) => `${i.path.join('.') || 'input'}: ${i.message}`)
    .join('; ')
  return { ok: false, message, issues: result.error.issues }
}

export function badRequest(c: Context, message: string) {
  return c.json({ error: 'bad_request', message }, 400)
}

/** Parse query string map from Hono into a schema; returns JSON 400 response on failure. */
export function parseQuery<T>(
  c: Context,
  schema: z.ZodType<T>,
  query: Record<string, string | undefined>
): T | Response {
  const parsed = parseSchema(schema, query)
  if (!parsed.ok) {
    return badRequest(c, parsed.message)
  }
  return parsed.data
}

/** Parse route params; returns JSON 400 response on failure. */
export function parseParams<T>(
  c: Context,
  schema: z.ZodType<T>,
  params: Record<string, string>
): T | Response {
  const parsed = parseSchema(schema, params)
  if (!parsed.ok) {
    return badRequest(c, parsed.message)
  }
  return parsed.data
}
