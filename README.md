# RunFuel — Android app & MCP server

RunFuel combines a Flutter Android training, nutrition and coaching app with an optional self-hosted remote [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server that connects Garmin Connect and MyFitnessPal data to AI assistants such as Claude and other clients that support remote MCP.

RunFuel MCP is designed for people who want their own private data connection. You deploy your own instance, connect your own accounts, and provide your own hosting and storage credentials. **There is no shared RunFuel server and no maintainer account or database to connect to.**

## What it does

- Exposes selected Garmin read tools and derived running summaries.
- Exposes read-only MyFitnessPal diary, goals, measurements, connection status and bounded history tools.
- Supports remote MCP over HTTPS with OAuth 2.1 and PKCE for compatible clients.
- Provides per-OAuth-principal MyFitnessPal connections. Native sign-in is the default; an optional cookie compatibility flow is also available.
- Encrypts managed credentials before storing them in your own Upstash Redis database.
- Includes a mobile-friendly credential manager at `/settings`.
- Filters known account/profile identifiers from returned data.
- Retrieves detailed GPS tracks only when explicitly requested for a selected activity, samples tracks to a maximum of 2,000 points, and processes the track in memory.
- Keeps MyFitnessPal food diary access read-only. No food diary write, edit or delete tools are exposed.

## Important account and privacy model

- **Garmin:** the Garmin Personal API credential is configured by the operator for that deployment. Treat Garmin access as deployment-wide; do not share your deployment with people who should not see that Garmin account.
- **MyFitnessPal:** each successful MCP OAuth authorization has its own isolated MyFitnessPal connection and encrypted credential record.
- **Hosting:** each operator must use their own Vercel project, Upstash Redis database, Garmin credentials and MyFitnessPal account(s).
- **No public multi-tenant service:** the shared RunFuel OAuth password protects one self-hosted deployment. It is not a public sign-up, billing or account-recovery system. Do not operate a shared public instance for unrelated users.
- **Privacy filtering is not anonymity:** upstream schemas can change. Activity timestamps, activity IDs, routes and health/nutrition metrics can still be sensitive. Review the privacy policy and only connect trusted clients.

## Quick start

1. Fork this repository into your own GitHub account or organisation.
2. Create your own Vercel project from that fork.
3. Create your own Upstash Redis database and connect its REST URL and token.
4. Configure the environment variables described in [Self-hosting RunFuel MCP](docs/SELF_HOSTING.md).
5. Deploy your own instance and open `https://YOUR-DOMAIN/health`.
6. Open `https://YOUR-DOMAIN/settings`, sign in with username `admin` and your own `RUNFUEL_OAUTH_PASSWORD`, and configure your Garmin credential.
7. Add your own deployment's MCP URL to Claude or another compatible client: `https://YOUR-DOMAIN/mcp`.
8. Complete OAuth, then use `mfp_connect_account` to connect your own MyFitnessPal account.

See the [complete self-hosting guide](docs/SELF_HOSTING.md) for detailed instructions and client setup.

## Endpoints

| Purpose | Your deployment endpoint |
| --- | --- |
| Remote MCP | `https://YOUR-DOMAIN/mcp` |
| Health check | `https://YOUR-DOMAIN/health` |
| Credential manager | `https://YOUR-DOMAIN/settings` |
| OAuth metadata | `https://YOUR-DOMAIN/.well-known/oauth-authorization-server` |

Replace `YOUR-DOMAIN` with the HTTPS domain assigned to your own Vercel deployment. Never use another person's endpoint or credentials.

## MyFitnessPal authentication modes

**Native mode (default):** each OAuth principal signs in to MyFitnessPal through a short-lived RunFuel connection page. Renewable credentials are encrypted and stored per principal. This currently relies on reverse-engineered MyFitnessPal mobile identity endpoints, not an official public API. It may stop working if MyFitnessPal changes those endpoints.

**Cookie mode (optional compatibility):** each OAuth principal can connect their own MyFitnessPal web session using a short-lived, single-use connection link. Cookies are encrypted per principal and never returned to the AI client. This mode can be affected by session expiry, Cloudflare or upstream website changes. Never share a cookie or use another person's session.

The mode is selected for the whole deployment with `MFP_AUTH_MODE=native` or `MFP_AUTH_MODE=cookie`. It is not selected independently for each user.

## RunFuel Android app

The repository now includes the public Flutter source for the RunFuel Android app in [app/](app/). It brings training plans, Garmin activity and recovery data, MyFitnessPal nutrition, food diary review, and coaching into one Android client. The app can be used independently of the MCP server; connecting a self-hosted RunFuel backend is optional for local features.

- [Android app overview and setup](app/README.md)
- [Build the Android ARM64 APK with GitHub Actions](app/BUILD.md)
- [AI coaching, data sharing and privacy](app/AI_OPTIONS.md)

The included GitHub Actions workflow runs Flutter tests and analysis, then builds a downloadable ARM64 APK. Permanent signing is optional for public builds: configure your own signing secrets to produce an APK that can update your existing installation. Without those secrets, the workflow produces a debug-signed artifact for fresh installs only. No signing keys, API keys or personal account credentials are included in the source.

## Requirements

- Python 3.12
- A GitHub account
- A Vercel account for hosting
- An Upstash Redis database
- A Garmin account and Garmin Personal API key
- A MyFitnessPal account
- Claude or another client that supports remote MCP and OAuth

## Development and tests

Install dependencies and run the test suite:

```bash
python -m venv .venv
# Activate the virtual environment, then:
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
```

Python 3.12 is required by the Garmin dependency. GitHub Actions runs the same unit-test suite on pushes and pull requests.

## Upstream projects and attribution

RunFuel integrates and builds on work from:

- [Garmin Personal MCP](https://github.com/Mason-Levyy/garmin-personal-mcp)
- [MyFitnessPal MCP](https://github.com/Mason-Levyy/myfitnesspal-mcp)

Thanks to the upstream authors and contributors. RunFuel is a separate integration project and does not claim authorship of those projects. Preserve upstream licence notices when redistributing. RunFuel's own contributions are licensed under the MIT License; see [LICENSE](LICENSE).

## Security

Never commit `.env`, API keys, MyFitnessPal passwords or cookies, OAuth tokens, Redis tokens, real diary exports, health data or GPS tracks. Keep all deployment secrets in your own Vercel environment variables. See [SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md).
