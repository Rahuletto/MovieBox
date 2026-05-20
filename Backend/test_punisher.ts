async function testPunisher() {
  const token = "165663371760d04a573abb26622164c12c508819da49dc01cc13c833d03ee9aa";
  const query = "The Punisher: One Last Kill";
  const url = `https://moviebox-backend.rahulmarban.workers.dev/api/tmdb/search/movie?query=${encodeURIComponent(query)}`;
  
  console.log(`Querying TMDB search: ${url}...`);
  try {
    const res = await fetch(url, { headers: { 'X-MovieBox-Token': token } });
    const payload = await res.json() as any;
    console.log("Search Results:", JSON.stringify(payload.results, null, 2));
    
    if (payload.results && payload.results.length > 0) {
      const first = payload.results[0];
      const detailUrl = `https://moviebox-backend.rahulmarban.workers.dev/api/title/movie/${first.id}`;
      console.log(`\nQuerying details: ${detailUrl}...`);
      const detailRes = await fetch(detailUrl, { headers: { 'X-MovieBox-Token': token } });
      const detailPayload = await detailRes.json() as any;
      console.log("Movie Detail:", JSON.stringify({
        title: detailPayload.title,
        release_date: detailPayload.release_date,
        runtime: detailPayload.runtime,
        imdbId: detailPayload.imdbId
      }, null, 2));
    }
  } catch (err: any) {
    console.error("Error:", err.message);
  }
}

testPunisher();
