const SUBF2M_FETCH_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  Accept: 'text/html,application/xhtml+xml',
  'Accept-Language': 'en-US,en;q=0.9',
}

async function resolveZip(downloadPageUrl) {
  const response = await fetch(downloadPageUrl, {
    redirect: 'manual',
    headers: { ...SUBF2M_FETCH_HEADERS, Referer: 'https://subf2m.co/' },
  })
  console.log('status', response.status)
  if (response.status >= 300 && response.status < 400) {
    const loc = response.headers.get('location')
    console.log('location', loc)
    return loc ? new URL(loc, downloadPageUrl).toString() : null
  }
  const html = await response.text()
  console.log('html len', html.length, html.slice(0, 120))
  const m = html.match(/window\.location\.href\s*=\s*["']([^"']+)["']/i)
  return m ? new URL(m[1], downloadPageUrl).toString() : null
}

const page = 'https://subf2m.co/subtitles/interstellar/english/3656763'
const dl = 'https://subf2m.co/subtitles/interstellar/english/3656763/download'

for (const url of [page, dl]) {
  console.log('\n===', url)
  const zip = await resolveZip(url)
  console.log('zip url', zip)
  if (zip) {
    const z = await fetch(zip, { headers: { ...SUBF2M_FETCH_HEADERS, Referer: url } })
    console.log('zip status', z.status, z.headers.get('content-type'), 'size', (await z.arrayBuffer()).byteLength)
  }
}
