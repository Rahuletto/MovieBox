async function testApibayDirectYear() {
  const query = "Fight Club 1999";
  const url = `https://apibay.org/q.php?q=${encodeURIComponent(query)}&cat=200`;
  console.log(`Querying apibay.org directly with year: ${url}...`);
  try {
    const res = await fetch(url);
    const data = await res.json() as any[];
    console.log(`Returned ${data.length} results.`);
    if (data.length > 0) {
      console.log("First 3 results:");
      console.log(JSON.stringify(data.slice(0, 3), null, 2));
    }
  } catch (err: any) {
    console.error("Error querying apibay:", err.message);
  }
}

testApibayDirectYear();
