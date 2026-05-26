import { timingSafeEqual } from 'node:crypto'

const encoder = new TextEncoder()

export function isValidAppToken(secret: string | undefined, candidate: string | null): boolean {
  if (!secret || !candidate) return false
  const left = encoder.encode(secret)
  const right = encoder.encode(candidate)
  if (left.byteLength !== right.byteLength) return false
  return timingSafeEqual(left, right)
}
