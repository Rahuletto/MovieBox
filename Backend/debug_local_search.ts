import { searchAllTorrents } from './src/torrent/search';

async function main() {
  const query = "Fight Club";
  console.log(`Running local search for: ${query}`);
  const result = await searchAllTorrents({
    query: query,
    year: 1999,
    kind: 'movie',
    enabledIndexerIDs: 'torrentio,yts,eztv,piratebay,1337x'
  });
  console.log("Counts:", result.counts);
  console.log("Errors:", result.errors);
  console.log("Number of results:", result.results.length);
}

main().catch(console.error);
