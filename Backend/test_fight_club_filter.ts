const USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36';

function normalize(value: string): string {
  return value.toLowerCase()
    .replace(/\./g, ' ')
    .replace(/_/g, ' ')
    .replace(/-/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function parseReleaseYear(normalized: string): number | null {
  const match = normalized.match(/\b(19|20)\d{2}\b/);
  return match ? parseInt(match[0], 10) : null;
}

function bitrateBoundsBps(normalized: string) {
  if (normalized.includes("2160p") || normalized.includes("4k")) {
    return { low: 8000000, high: 45000000 };
  }
  if (normalized.includes("1080p")) {
    if (normalized.includes("h265") || normalized.includes("hevc") || normalized.includes("x265")) {
      return { low: 1500000, high: 12000000 };
    }
    return { low: 2500000, high: 15000000 };
  }
  if (normalized.includes("720p")) {
    return { low: 1000000, high: 8000000 };
  }
  if (normalized.includes("480p") || normalized.includes("360p")) {
    return { low: 500000, high: 2500000 };
  }
  return { low: 2000000, high: 12000000 };
}

function matchesExpectedRuntime(sizeBytes: number, normalized: string, runtimeMinutes: number): boolean {
  if (sizeBytes <= 0 || runtimeMinutes < 15) return true;
  const bounds = bitrateBoundsBps(normalized);
  const expectedSeconds = runtimeMinutes * 60;
  const buffer = 5 * 60; // runtimeBufferMinutes
  const windowMin = Math.max(60, expectedSeconds - buffer);
  const windowMax = expectedSeconds + buffer;

  const estMinSeconds = (sizeBytes * 8) / bounds.high;
  const estMaxSeconds = (sizeBytes * 8) / bounds.low;
  return estMaxSeconds >= windowMin && estMinSeconds <= windowMax;
}

function matchesTitlePrefix(normalized: string, movieTokens: string[]): boolean {
  const joined = movieTokens.join(" ");
  if (normalized.startsWith(joined) || normalized.startsWith("the " + joined)) {
    return true;
  }
  const dotted = movieTokens.join(".");
  if (normalized.startsWith(dotted) || normalized.startsWith("the." + dotted)) {
    return true;
  }
  return false;
}

function containsAllTokens(normalized: string, tokens: string[]): boolean {
  const dotted = normalized.replace(/ /g, '.');
  return tokens.every(token => {
    const lower = token.toLowerCase();
    return normalized.includes(lower) || dotted.includes(lower);
  });
}

function isHardExcluded(title: string, movieTokens: string[], sizeBytes: number, runtimeMinutes: number | null): boolean {
  const normalized = normalize(title);

  // 1. Non-movie markers
  const nonMovieMarkers = [
    "daily show", "jimmy kimmel", "late show", "tonight show", "fallon", "conan", "colbert",
    "ellen", "talk show", "snl", "saturday night live", "last week tonight", "real time with",
    "podcast", "interview", "unrated clip", "bonus feature", "behind the scenes",
    "deleted scene", "gag reel", "featurette", "after show",
  ];
  if (nonMovieMarkers.some(marker => normalized.includes(marker))) return true;

  // 2. TV episode
  if (/\bS\d{1,2}E\d{2,4}\b/i.test(normalized)) return true;
  if (/\b\d{1,2}[xX]\d{2,3}\b/.test(normalized)) return true;
  if (normalized.includes("season ") && normalized.includes("episode")) return true;

  // 3. Runtime check
  if (runtimeMinutes && sizeBytes > 0) {
    if (!matchesExpectedRuntime(sizeBytes, normalized, runtimeMinutes)) {
      return true;
    }
  }

  return false;
}

function titleTokens(movieTitle: string): string[] {
  return normalize(movieTitle)
    .split(/[^a-z0-9]/)
    .filter(Boolean);
}

function relevanceScore(title: string, movieTokens: string[], year: number | null, sizeBytes: number, runtimeMinutes: number | null): number {
  if (isHardExcluded(title, movieTokens, sizeBytes, runtimeMinutes)) {
    return 0;
  }

  const normalized = normalize(title);
  if (movieTokens.length === 0) return 1;

  let score = 0;

  if (matchesTitlePrefix(normalized, movieTokens)) {
    score += 80;
  } else if (containsAllTokens(normalized, movieTokens)) {
    score += 40;
  } else {
    return 0;
  }

  // Year check
  if (year) {
    const releaseYear = parseReleaseYear(normalized);
    if (releaseYear !== null) {
      if (Math.abs(releaseYear - year) <= 1) {
        score += 35;
      } else if (Math.abs(releaseYear - year) > 3) {
        return 0;
      } else {
        score += 15;
      }
    } else {
      if (normalized.includes(String(year))) {
        score += 15;
      }
      // If single token ambiguous title, return 0 (not applicable for Fight Club)
    }
  }

  if (runtimeMinutes && matchesExpectedRuntime(sizeBytes, normalized, runtimeMinutes)) {
    score += 20;
  } else if (runtimeMinutes && sizeBytes > 0) {
    return 0;
  } else if (sizeBytes > 0) {
    score += 10;
  }

  if (normalized.includes("webrip") || normalized.includes("bluray") || normalized.includes("remux")) {
    score += 8;
  }
  if (normalized.includes("hdts") || normalized.includes("telesync") || normalized.includes(" cam ")) {
    score -= 20;
  }

  return score;
}

async function testFilter() {
  const token = "165663371760d04a573abb26622164c12c508819da49dc01cc13c833d03ee9aa";
  const url = "https://moviebox-backend.rahulmarban.workers.dev/api/torrent/search?q=Fight+Club&kind=movie&year=1999&enabled=torrentio,yts,eztv,piratebay,1337x";
  
  console.log(`Fetching results from: ${url}`);
  const res = await fetch(url, { headers: { 'X-MovieBox-Token': token } });
  const payload = await res.json() as any;
  const results = payload.results || [];
  
  const expectedTitle = "Fight Club";
  const expectedYear = 1999;
  const expectedRuntime = 139;
  const tokens = titleTokens(expectedTitle);

  let scored: any[] = [];
  let excluded: any[] = [];

  for (const item of results) {
    const score = relevanceScore(item.title, tokens, expectedYear, item.sizeBytes || 0, expectedRuntime);
    if (score > 0) {
      scored.push({ item, score });
    } else {
      excluded.push(item);
    }
  }

  console.log(`\n--- PASSED RESULTS (${scored.length}) ---`);
  scored.sort((a,b) => b.score - a.score).forEach(x => {
    console.log(`[Score: ${x.score}] ${x.item.title} (Source: ${x.item.trackerSource}, Seeds: ${x.item.seeders}, Size: ${(x.item.sizeBytes / (1024*1024)).toFixed(1)} MB)`);
  });

  console.log(`\n--- EXCLUDED RESULTS (${excluded.length}) ---`);
  excluded.slice(0, 20).forEach(x => {
    const norm = normalize(x.title);
    const bounds = bitrateBoundsBps(norm);
    const estMin = ((x.sizeBytes || 0) * 8) / bounds.high / 60;
    const estMax = ((x.sizeBytes || 0) * 8) / bounds.low / 60;
    console.log(`- Title: ${x.title} (Source: ${x.trackerSource}, Size: ${((x.sizeBytes || 0) / (1024*1024)).toFixed(1)} MB, Est length: ${estMin.toFixed(1)} to ${estMax.toFixed(1)} mins)`);
  });
}

testFilter().catch(console.error);
