# Contributing to RunFuel

Thanks for considering a contribution.

## Before opening a pull request

- Explain the problem and the intended behaviour.
- Keep changes focused and include tests for changed behaviour where practical.
- Preserve the MyFitnessPal read-only boundary. Do not add diary write, edit, or delete tools.
- Keep Garmin as the source of truth for activity/step data; do not reintroduce MyFitnessPal exercise tools.
- Do not remove GPS coordinates from the internal activity-track path without discussing the impact on route/run analysis.
- Avoid returning unnecessary identity fields, credentials, raw cookies, tokens, diary data, or GPS coordinates in logs, errors, test output, issues, or pull requests.
- Update README or the relevant documentation when configuration, tool exposure, privacy behaviour, or deployment requirements change.
- Run the tests with Python 3.12: `python -m unittest discover -s tests -v`.

## Security and privacy

Never submit real credentials or personal fitness/nutrition/location data in a test fixture. Use synthetic examples. For potential vulnerabilities, follow [SECURITY.md](SECURITY.md) and do not disclose exploit details publicly before coordinated review.

## Upstream components

RunFuel integrates the published projects by Mason-Levyy:
- [Garmin Personal MCP](https://github.com/Mason-Levyy/garmin-personal-mcp)
- [MyFitnessPal MCP](https://github.com/Mason-Levyy/myfitnesspal-mcp)

Please preserve attribution and licence notices when changing or redistributing upstream-derived code.
