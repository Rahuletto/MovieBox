async function testFightClubResults() {
  const token = "165663371760d04a573abb26622164c12c508819da49dc01cc13c833d03ee9aa";
  const url = "https://moviebox-backend.rahulmarban.workers.dev/api/torrent/search?q=Fight+Club&kind=movie&year=1999&enabled=torrentio,yts,eztv,piratebay,1337x";
  console.log(`Querying ${url}...`);
  try {
    const res = await fetch(url, { headers: { 'X-MovieBox-Token': token } });
    const payload = await res.json() as any;
    console.log("Counts:", payload.counts);
    console.log("Errors:", payload.errors);
    console.log("Number of results:", payload.results?.length);
    if (payload.results && payload.results.length > 0) {
      console.log("\nFirst 10 Results list:");
      for (const item of payload.results.slice(0, 10)) {
        console.log(`- Title: ${item.title} (Source: ${item.trackerSource}, Seeds: ${item.seeders}, Size: ${(item.sizeBytes / (1024*1024)).toFixed(1)} MB)`);
      }
    }
  } catch (err: any) {
    console.error("Error:", err.message);
  }
}

testFightClubResults();
