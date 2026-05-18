/** Build a TMDB API URL from the incoming Worker request (path + query only). */
export function buildTMDBUpstreamURL(requestURL: string, apiPath: string): string {
  const incoming = new URL(requestURL)
  const path = apiPath.startsWith('/') ? apiPath : `/${apiPath}`
  const upstream = new URL(`https://api.themoviedb.org/3${path}`)
  upstream.search = incoming.search
  return upstream.toString()
}

export function tmdbPathFromRequest(requestPath: string): string {
  return requestPath.replace(/^\/api\/tmdb/, '') || '/'
}
