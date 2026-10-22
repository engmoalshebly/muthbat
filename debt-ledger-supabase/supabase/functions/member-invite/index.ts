Deno.serve(async (request) => {
  return new Response(JSON.stringify({ error: "feature_disabled" }), {
    status: 410,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
});
