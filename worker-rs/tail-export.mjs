export async function shipTailEvents(env, events, send = fetch) {
  const url = env.BETTERSTACK_LOGS_URL;
  const token = env.BETTERSTACK_LOGS_TOKEN;
  if (!url || !token) return;
  try {
    await send(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(events),
    });
  } catch {}
}
