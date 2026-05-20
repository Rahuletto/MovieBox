async function testPunisherResults() {
  const token = "165663371760d04a573abb26622164c12c508819da49dc01cc13c833d03ee9aa";
  const url = "https://moviebox-backend.rahulmarban.workers.dev/api/torrent/search?q=The+Punisher+One+Last+Kill&kind=movie&year=2026&enabled=torrentio,yts,eztv,piratebay,1337x";
  console.log(`Querying ${url}...`);
  try {
    const res = await fetch(url, { headers: { 'X-MovieBox-Token': token } });
    const payload = await res.json() as any;
    console.log("Counts:", payload.counts);
    console.log("Errors:", payload.errors);
    console.log("Number of results:", payload.results?.length);
    if (payload.results && payload.results.length > 0) {
      console.log("Results list:");
      for (const item of payload.results) {
        console.log(`- Title: ${item.title} (Source: ${item.trackerSource}, Seeds: ${item.seeders}, Size: ${(item.sizeBytes / (1024*1024)).toFixed(1)} MB)`);
      }
    }
  } catch (err: any) {
    console.error("Error:", err.message);
  }
}

testPunisherResults();
