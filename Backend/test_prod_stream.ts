import { IncomingMessage } from 'http';
import * as https from 'https';

function testProdStream() {
  const token = "165663371760d04a573abb26622164c12c508819da49dc01cc13c833d03ee9aa";
  const url = "https://moviebox-backend.rahulmarban.workers.dev/api/torrent/search/stream?q=Project+Hail+Mary&kind=movie&year=2026&enabled=torrentio,yts,eztv,piratebay,1337x";
  
  console.log(`Querying stream: ${url}...`);
  
  const options = {
    headers: {
      'X-MovieBox-Token': token,
      'Accept': 'text/event-stream'
    }
  };
  
  const req = https.get(url, options, (res) => {
    console.log(`HTTP Status: ${res.statusCode}`);
    console.log(`Content-Type: ${res.headers['content-type']}`);
    
    res.on('data', (chunk) => {
      const text = chunk.toString();
      console.log(`\n--- Received chunk (${chunk.length} bytes) ---`);
      // Print first 300 chars of chunk to avoid blowing up terminal
      console.log(text.length > 500 ? text.slice(0, 500) + '...' : text);
    });
    
    res.on('end', () => {
      console.log("\n--- Stream Finished ---");
    });
  });
  
  req.on('error', (e) => {
    console.error(`Request error: ${e.message}`);
  });
}

testProdStream();
