# RunFuel data-minimization policy

RunFuel is intended to retain the information needed for useful coaching while avoiding unnecessary personal identity data.

## Keep for coaching and analysis

- Garmin activity records and activity-detail fields needed for coaching.
- Distance, duration, pace, splits, elevation, heart rate, cadence, timestamps, and other training fields when available from the source.
- Detailed GPS coordinates and route geometry only when the user explicitly requests the track for a selected activity.
- Daily wellness, sleep, heart-rate, steps, weight, and nutrition data required for the user's coaching goals.
- MyFitnessPal bulk exports default to a 7-day window and are capped at 31 days per request. Longer history should be retrieved as separate smaller windows; callers should avoid enabling upstream sync for broad historical ranges unless needed.
- Activity identifiers where needed to match or compare the same activity across reads.

Detailed GPS coordinates must be **on-demand, not part of routine activity reads**. Normal daily summaries, activity searches, activity details, and running summaries should return coaching metrics without coordinate arrays or route geometry. The dedicated `garmin_get_activity_track` tool is the only route-data path: call it only when the user explicitly requests route-level analysis for a selected activity. It downloads that one activity's FIT archive, parses it in memory, and returns evenly sampled points (maximum 2,000 by default and hard limit). The archive and parsed track are not persisted. If no GPS records exist, the tool reports that rather than inventing a route. This reduces unnecessary GPS downloads, response size, and processing while retaining route analysis when requested.

## Minimize identity data

- The Garmin profile tool is not exposed through RunFuel's public MCP allowlist.
- Apply recursive key-based sanitization to every exposed Garmin and MyFitnessPal response, including nested objects, lists, derived metrics, diagnostics, aliases, and GPS-track results.
- Remove account/profile/device identifiers (including alternate names such as `userDailySummaryId`), account names, email/name fields, avatar/profile URLs, and owner metadata wherever they appear.
- Preserve activity IDs, food/meal names, dates, nutrition values, and training metrics in ordinary responses. Strip GPS coordinate and route-geometry fields from ordinary Garmin responses; preserve `lat`/`lon` only in the explicitly requested dedicated track-tool response.
- Do not log credentials, session cookies, OAuth tokens, or full raw payloads containing personal data.
- Keep MyFitnessPal exercise entries excluded because Garmin is the exercise source of truth.

## Deployment and data handling

RunFuel is self-hosted by each operator. Within an installation, each successful OAuth authorization is assigned a distinct opaque RunFuel principal. Native MyFitnessPal access and refresh tokens are encrypted and stored under that principal, and MCP requests resolve the principal from the presented bearer token. MyFitnessPal tools and the mobile sync endpoint do not fall back to a shared cookie, preventing one authorization from receiving another user's diary. A separate OAuth authorization creates a separate MFP connection; reconnecting a client may therefore require connecting MyFitnessPal again. Production operators should set an explicit `RUNFUEL_BASE_URL`; Vercel preview deployments can use their Vercel-provided deployment host when it is absent. The server never silently uses the maintainer's hosted endpoint. The operator's hosting provider, Redis provider, and connected services process the data needed to fulfil requests. Depending on the deployment and upstream behaviour, activity, wellness, nutrition, and GPS data may pass through the RunFuel server in memory; managed credentials and per-user native MyFitnessPal token pairs are encrypted before being stored in Redis. MyFitnessPal passwords are used only during the native sign-in exchange and are not persisted. The native identity flow relies on reverse-engineered mobile endpoints rather than an officially supported public API, so its availability and behaviour can change. Do not assume that the source data is anonymous merely because profile identifiers are filtered from tool responses.

Operators should restrict access to their deployment, use HTTPS, keep Vercel and Redis credentials private, review provider retention and access settings, and avoid logging raw payloads. GPS tracks can reveal home, work, and personal routines; expose them only to trusted clients and consider whether full route data is needed for each analysis.

RunFuel's sanitization reduces identity fields in tool responses but is not a guarantee of anonymity or a substitute for securing the server, OAuth credentials, or upstream accounts. Upstream schemas can change, so review and test responses after dependency updates.

## Read-only boundary

RunFuel remains read-only for MyFitnessPal diary data. The privacy changes do not add any diary-writing, editing, or deletion capability.

## Important distinction

Removing the profile tool from the allowlist prevents clients from directly requesting that profile operation through RunFuel. It does not guarantee that every upstream activity response is free of identity fields. Response sanitization is implemented across all exposed data pools and is covered by regression tests for nested, case-varied, and alternate identifier keys. Because filtering is key-based, new upstream response fields should still be reviewed and added to the tests when they are introduced.
