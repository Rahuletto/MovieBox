import { SELF } from 'cloudflare:test'

declare module 'cloudflare:test' {
  interface ProvidedEnv extends Env {}
}
