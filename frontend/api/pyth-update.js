// Vercel serverless function — proxies Pyth's Hermes price service so the
// browser deposit flow (app.html) never has to embed HERMES_API_KEY.
//
// Hermes requires an API key (Authorization: Bearer <key>); a static site
// has nothing to hide it behind, so this one small server-side function
// holds it instead (set HERMES_API_KEY in the Vercel project's environment
// variables — never commit it). Mirrors solver/src/pyth.ts's
// fetchPythUpdateData exactly, just running server-side instead of in the
// solver's Node process.
//
// GET /api/pyth-update?feedId=<hex,hex,...>  (no 0x prefix, comma-separated
// for multiple feeds — duplicates are fine, Hermes returns one blob per
// distinct id either way)
// -> { data: ["0x...", ...] }

module.exports = async (req, res) => {
  const feedIdParam = req.query.feedId;
  if (!feedIdParam) {
    res.status(400).json({ error: "feedId query param is required (comma-separated for multiple)" });
    return;
  }

  const apiKey = process.env.HERMES_API_KEY;
  if (!apiKey) {
    res.status(500).json({ error: "HERMES_API_KEY is not configured on the server" });
    return;
  }

  const ids = [...new Set(String(feedIdParam).split(",").map((s) => s.trim()).filter(Boolean))];
  const params = ids.map((id) => `ids%5B%5D=${id}`).join("&");
  const url = `https://hermes.pyth.network/v2/updates/price/latest?${params}&encoding=hex`;

  let upstream;
  try {
    upstream = await fetch(url, { headers: { Authorization: `Bearer ${apiKey}` } });
  } catch (err) {
    res.status(502).json({ error: `Hermes request failed: ${err.message}` });
    return;
  }

  if (!upstream.ok) {
    const hint = upstream.status === 401 ? " (check HERMES_API_KEY)" : "";
    res.status(upstream.status).json({ error: `Hermes returned ${upstream.status}${hint}` });
    return;
  }

  const body = await upstream.json();
  const data = (body.binary?.data || []).map((d) => (d.startsWith("0x") ? d : `0x${d}`));

  // Every response is a fresh, time-sensitive price update — never cache it.
  res.setHeader("Cache-Control", "no-store");
  res.status(200).json({ data });
};
