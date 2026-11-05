# Self-hosting RunFuel MCP

This guide is for people deploying their own RunFuel MCP server. RunFuel is not a hosted service: each operator owns their deployment, database, credentials and upstream account connections.

## 1. Create your own copy

1. Fork the RunFuel MCP repository into your own GitHub account or organisation.
2. Keep the default branch as `main`.
3. Do not add credentials to repository files, commits, issues, pull requests or screenshots.
4. Import your fork into Vercel. Keep the repository root as the project root and use the detected Python configuration.

Do not connect your fork to another person's Vercel project, Redis database, Garmin credential or MyFitnessPal session.

## 2. Create a dedicated Upstash Redis database

RunFuel uses Redis for OAuth state and tokens, rate limiting, and encrypted managed credentials.

1. Create your own Redis database in the [Upstash Console](https://console.upstash.com/).
2. Copy its REST URL and REST token.
3. Add them to your own Vercel project as `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`.
4. Never publish the REST token.

Use a separate database for each RunFuel deployment.

## 3. Configure Vercel environment variables

In your Vercel project, open **Settings → Environment Variables**. Add the following values for Production, then redeploy.

| Variable | Required | Description |
| --- | --- | --- |
| `RUNFUEL_BASE_URL` | Recommended | Canonical HTTPS origin of your deployment, without a trailing slash, e.g. `https://your-project.vercel.app`. |
| `RUNFUEL_OAUTH_PASSWORD` | Yes | A long, unique password for OAuth sign-in and Token Manager Basic Auth. |
| `UPSTASH_REDIS_REST_URL` | Yes | Your own Upstash Redis REST URL. |
| `UPSTASH_REDIS_REST_TOKEN` | Yes | Your own Upstash Redis REST token. |
| `GARMIN_PERSONAL_API_KEY` | Yes for Garmin | Your own Garmin Personal API key. It can also be entered in Token Manager. |
| `MFP_AUTH_MODE` | Optional | `native` (default) or `cookie`; applies to the whole deployment. |
| `MFP_NATIVE_CLIENT_ID` | Native mode | Native MyFitnessPal mobile identity client ID; keep server-side. |
| `MFP_NATIVE_CLIENT_SECRET` | Native mode | Native MyFitnessPal mobile identity client secret; keep server-side. |
| `RUNFUEL_SECRET_ENCRYPTION_KEY` | Optional | Dedicated Fernet key for managed credentials. Normally RunFuel derives a key from the OAuth password and Redis token. |
| `MFP_COOKIE` | Legacy only | Old shared-cookie compatibility setting. Do not use it for per-user connections. |
| `MFP_USERNAME` | Legacy only | Old shared-cookie compatibility setting. |
| `MFP_MCP_DATA_DIR` | Optional | Local cache directory; use `/tmp/runfuel-mfp` on Vercel. |
| `RUNFUEL_ACCESS_TOKEN` | Optional legacy | Static bearer-token fallback. Prefer OAuth. |

A placeholder template is provided in [`.env.example`](../.env.example). Copy it only for local development and replace every placeholder with your own values. Never commit a real `.env` file.

**Important encryption note:** if you do not set `RUNFUEL_SECRET_ENCRYPTION_KEY`, the managed-credential encryption key is derived from `RUNFUEL_OAUTH_PASSWORD` and `UPSTASH_REDIS_REST_TOKEN`. Keep both stable while encrypted credentials are stored. Changing either can make existing credentials unreadable. If you need to rotate them, plan a credential re-entry or migration first.

## 4. Deploy and open Token Manager

1. Confirm that the Vercel deployment is **Ready**.
2. Open `https://YOUR-DOMAIN/health`. A successful response confirms that the service responds; it does not validate upstream account connections.
3. Open `https://YOUR-DOMAIN/settings`.
4. Sign in with username `admin` and the `RUNFUEL_OAUTH_PASSWORD` you configured.
5. Add your own `GARMIN_PERSONAL_API_KEY` if you have not already set it in Vercel.
6. Save the settings.

Use HTTPS only. Do not expose Token Manager or share its password.

## 5. Connect an MCP client

### Claude

Claude supports custom remote MCP connectors. The exact menu labels can change, but the usual setup is:

1. Open Claude **Settings → Connectors** (or **Customize → Connectors**).
2. Choose **Add** and select a custom remote MCP server.
3. Enter your endpoint: `https://YOUR-DOMAIN/mcp`.
4. Choose OAuth/sign-in when prompted.
5. Complete the browser authorization using your own RunFuel OAuth password.
6. Confirm RunFuel appears as connected.

Claude's current instructions for custom remote MCP connectors are in its [Help Center](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp).

### Other AI clients

RunFuel implements remote MCP over HTTPS with OAuth. Other assistants, agent frameworks and APIs can connect if they support the relevant remote MCP transport and OAuth flow. Follow that client's own instructions and use your own `https://YOUR-DOMAIN/mcp` endpoint. Do not assume every AI chat product supports remote MCP natively.

For example, OpenAI's Responses API documents remote MCP server connections in its [MCP guide](https://developers.openai.com/api/docs/guides/tools-connectors-mcp). Use the authentication method required by your own client.

## 6. Connect MyFitnessPal

The MyFitnessPal connection is per OAuth principal. After RunFuel is connected in your AI client:

1. Call `mfp_connect_account`.
2. Open the one-time connection link returned by RunFuel.
3. In native mode, sign in to your own MyFitnessPal account on the RunFuel page.
4. Return to your AI client and call `mfp_connection_status` or `mfp_get_diary` to confirm the connection.

Native mode is the default. It uses reverse-engineered MyFitnessPal mobile identity endpoints, not an official public API, and may stop working if MyFitnessPal changes those endpoints. MyFitnessPal passwords are used for the sign-in exchange and are not persisted; renewable tokens are encrypted and stored per OAuth principal.

### Optional cookie compatibility mode

If native mode is unavailable, the operator can set `MFP_AUTH_MODE=cookie` in Vercel and redeploy. Each MCP principal can then connect their own MyFitnessPal web session using the one-time link returned by `mfp_connect_account`. The cookie is encrypted per principal and is never returned to the AI client.

Cookie mode can be affected by upstream session expiry, Cloudflare or website changes. Never share a cookie, connect another person's account, or paste a cookie into AI chat, GitHub, issues or screenshots. The mode is global for the deployment, not independently selectable for each MCP principal.

## 7. Understand the account boundaries

- Garmin credentials are configured by the deployment operator. Treat the Garmin account as deployment-wide. Do not share a deployment with people who should not see that Garmin account.
- MyFitnessPal credentials are isolated per OAuth principal.
- The shared OAuth password protects one self-hosted installation. It is not a public registration system, and RunFuel is not designed to be a shared public multi-tenant SaaS.
- Each operator must provide their own Vercel project, Upstash database, Garmin credentials and MyFitnessPal account.
- Disconnecting an MCP client or revoking its OAuth access prevents that authorization from using RunFuel. Review your hosting and Redis access separately.

## 8. Privacy and GPS

Routine Garmin responses are filtered to remove known account/profile fields and detailed route geometry. The dedicated `garmin_get_activity_track` tool retrieves GPS only when explicitly requested for a selected activity, samples the route to a maximum of 2,000 points, and processes it in memory. Route coordinates can reveal home, work and personal routines. Only request them when needed and only connect trusted AI clients.

MyFitnessPal diary access is read-only. History exports default to a bounded window and are capped at 31 days per request. Review [PRIVACY.md](../PRIVACY.md) before connecting personal accounts.

## 9. Run tests locally

Python 3.12 is required by the Garmin dependency:

```bash
python -m venv .venv
# Activate the virtual environment, then:
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
```

The repository includes a GitHub Actions workflow that runs the unit tests on pushes and pull requests.
