const CALLBACK_PATH = "/patreon/callback";
const SESSION_TTL_SECONDS = 600;
const PATREON_CAMPAIGN = "emappleflagship";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method !== "GET") {
      return json({ error: "Method not allowed" }, 405, { Allow: "GET" });
    }

    if (url.pathname === "/health") {
      return json({ ok: true, service: "emload-patreon" });
    }

    if (url.pathname === "/auth/start") {
      return beginAuthorization(url, env);
    }

    if (url.pathname === CALLBACK_PATH) {
      return finishAuthorization(url, env);
    }

    if (url.pathname === "/api/session") {
      return readSession(url, env);
    }

    return json({ error: "Not found" }, 404);
  },
};

async function beginAuthorization(url, env) {
  const sessionId = url.searchParams.get("session_id") ?? "";
  if (!isUuid(sessionId)) {
    return json({ error: "A valid session_id is required" }, 400);
  }
  if (!env.PATREON_SESSIONS) {
    return json({ error: "Subscription storage is not configured" }, 503);
  }
  if (!env.PATREON_CLIENT_SECRET) {
    return json({ error: "Patreon OAuth is not configured" }, 503);
  }

  const state = crypto.randomUUID();
  await env.PATREON_SESSIONS.put(`state:${state}`, sessionId, {
    expirationTtl: SESSION_TTL_SECONDS,
  });

  const redirectUri = callbackUri(url);
  const authorize = new URL("https://www.patreon.com/oauth2/authorize");
  authorize.searchParams.set("response_type", "code");
  authorize.searchParams.set("client_id", env.PATREON_CLIENT_ID);
  authorize.searchParams.set("redirect_uri", redirectUri);
  authorize.searchParams.set("scope", "identity identity.memberships");
  authorize.searchParams.set("state", state);

  return Response.redirect(authorize.toString(), 302);
}

async function finishAuthorization(url, env) {
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const sessionId = state ? await env.PATREON_SESSIONS?.get(`state:${state}`) : null;

  if (!code || !state || !sessionId) {
    return callbackPage("We could not verify this Patreon response. Return to EmLoad and try again.", 400);
  }

  await env.PATREON_SESSIONS.delete(`state:${state}`);

  try {
    const tokenResponse = await fetch("https://www.patreon.com/api/oauth2/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        grant_type: "authorization_code",
        client_id: env.PATREON_CLIENT_ID,
        client_secret: env.PATREON_CLIENT_SECRET,
        redirect_uri: callbackUri(url),
      }),
    });

    if (!tokenResponse.ok) {
      return callbackPage("Patreon could not complete authorization. Return to EmLoad and try again.", 502);
    }
    const token = await tokenResponse.json();

    const identityUrl = new URL("https://www.patreon.com/api/oauth2/v2/identity");
    identityUrl.searchParams.set(
      "include",
      "memberships,memberships.campaign,memberships.currently_entitled_tiers",
    );
    identityUrl.searchParams.set(
      "fields[member]",
      "patron_status,last_charge_status,currently_entitled_amount_cents",
    );
    identityUrl.searchParams.set("fields[campaign]", "vanity,name");
    identityUrl.searchParams.set("fields[tier]", "title");

    const identityResponse = await fetch(identityUrl, {
      headers: { Authorization: `Bearer ${token.access_token}` },
    });
    if (!identityResponse.ok) {
      return callbackPage("We could not read your Patreon memberships. Return to EmLoad and try again.", 502);
    }

    const identity = await identityResponse.json();
    const tier = emloadTier(identity);
    await env.PATREON_SESSIONS.put(
      `result:${sessionId}`,
      JSON.stringify({ status: "complete", tier }),
      { expirationTtl: SESSION_TTL_SECONDS },
    );

    const message = tier
      ? `Patreon connected. EmLoad ${tier} is active. Return to EmLoad to continue.`
      : "Patreon connected, but no active Em Basic or Em Pro membership was found for EmAppleFlagship.";
    return callbackPage(message);
  } catch {
    return callbackPage("Patreon authorization failed. Return to EmLoad and try again.", 502);
  }
}

async function readSession(url, env) {
  const sessionId = url.searchParams.get("session_id") ?? "";
  if (!isUuid(sessionId)) {
    return json({ error: "A valid session_id is required" }, 400);
  }
  const stored = await env.PATREON_SESSIONS?.get(`result:${sessionId}`);
  if (!stored) {
    return json({ status: "pending" });
  }
  return json(JSON.parse(stored));
}

function emloadTier(identity) {
  const included = identity.included ?? [];
  const campaigns = new Map(
    included.filter((item) => item.type === "campaign").map((item) => [item.id, item.attributes ?? {}]),
  );
  const tiers = new Map(
    included.filter((item) => item.type === "tier").map((item) => [item.id, item.attributes?.title ?? ""]),
  );

  for (const member of included.filter((item) => item.type === "member")) {
    if (member.attributes?.patron_status !== "active_patron") continue;

    const campaignId = member.relationships?.campaign?.data?.id;
    const campaign = campaigns.get(campaignId);
    const creator = String(campaign?.vanity ?? campaign?.name ?? "").toLowerCase();
    if (creator !== PATREON_CAMPAIGN) continue;

    const entitledTiers = member.relationships?.currently_entitled_tiers?.data ?? [];
    const titles = entitledTiers.map((tier) => tiers.get(tier.id)?.toLowerCase());
    if (titles.includes("em pro")) return "Pro";
    if (titles.includes("em basic")) return "Plus";
  }
  return null;
}

function callbackUri(url) {
  return `${url.origin}${CALLBACK_PATH}`;
}

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function json(value, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}

function callbackPage(message, status = 200) {
  const safeMessage = escapeHtml(message);
  return new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>EmLoad Patreon</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111318;color:#f4f4f6;font:16px/1.5 system-ui,sans-serif}main{max-width:34rem;margin:1.5rem;padding:2rem;border:1px solid #333640;border-radius:1rem;background:#191b22}p{color:#c4c6ce}</style></head><body><main><h1>EmLoad Patreon</h1><p>${safeMessage}</p><p>You may close this tab and return to EmLoad.</p></main><script>history.replaceState(null,"",location.pathname)</script></body></html>`,
    {
      status,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
      },
    },
  );
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character]);
}
