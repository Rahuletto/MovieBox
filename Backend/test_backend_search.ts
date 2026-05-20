import { searchAllTorrents } from './src/torrent/search';

async function testLocalSearch() {
  console.log("Running local searchAllTorrents...");
  try {
    const payload = await searchAllTorrents({
      query: "Project Hail Mary",
      kind: "movie",
      enabledIndexerIDs: "torrentio,yts,eztv,piratebay,1337x",
    });
    console.log("Search complete!");
    console.log(`Returned ${payload.results.length} total results.`);
    console.log("Counts per provider:", payload.counts);
    console.log("Errors per provider:", payload.errors);
    
    console.log("\nFirst 10 results:");
    for (const r of payload.results.slice(0, 10)) {
      console.log(`- [${r.trackerSource}] ${r.title} (Seeds: ${r.seeders})`);
    }
  } catch (err: any) {
    console.error("Local search error:", err);
  }
}

testLocalSearch();
