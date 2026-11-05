# Security Policy

## Supported version

Security fixes are intended for the latest code on the `main` branch. Before reporting a vulnerability, update to the latest commit and check whether the issue still reproduces.

## Reporting a vulnerability

Please do not disclose vulnerabilities in a public issue, pull request, discussion, or social post before the maintainer has had a reasonable opportunity to investigate.

- If GitHub private vulnerability reporting is enabled for this repository, use that channel.
- Otherwise, contact the repository maintainer privately through GitHub and ask for a coordinated disclosure channel before sharing technical details.
- If private contact is not available, report only that a security issue exists in a public issue and ask for a private channel. Do not include exploit steps, credentials, personal data, or sensitive payloads.

Please include the affected component or file, impact, steps to reproduce using test data, and any suggested mitigation. Never include live MyFitnessPal cookies, Garmin keys, OAuth tokens, Redis credentials, private health data, or raw GPS tracks in a report.

## Scope and safety

RunFuel handles sensitive fitness, wellness, nutrition, account, and location data. Security reports are especially relevant to:

- Authentication, OAuth, token handling, and access-control bypasses.
- Credential storage, encryption, and accidental secret disclosure.
- Exposure of account identifiers or personal data through tool results, logs, errors, or diagnostics.
- Unexpected write-capable MyFitnessPal tools or other violations of the read-only boundary.
- Server-side request, deployment, or configuration weaknesses that affect a self-hosted instance.

Please test only systems and accounts you own or have explicit permission to assess. Do not access another person's data, disrupt service, or use real credentials in proof-of-concept reports.

## Response expectations

The maintainer will make a best-effort attempt to acknowledge and investigate reports, but no response or remediation deadline is guaranteed. Please allow reasonable time for investigation and a fix before public disclosure.
