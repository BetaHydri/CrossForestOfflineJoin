# Security Policy

## Maintenance model / Wartungsmodell

This project is **open source and community-maintained on a best-effort
basis**. Security fixes and further development are provided by the maintainer
and contributors through this public repository. There is **no commercial
Service Level Agreement (SLA)** unless separately agreed in writing.

Because the project is distributed under an open-source license (see
[LICENSE](LICENSE)), any organisation may additionally fork, audit, and
self-maintain the code to satisfy internal assurance requirements.

> **BSI IT-Grundschutz context:** Maintenance and the supply of security
> updates are ensured via active community/maintainer development (documented in
> [CHANGELOG.md](CHANGELOG.md) and the GitHub release history). Operators with
> **high or very high protection needs** should complement this with their own
> internal maintenance responsibility or a dedicated support agreement, as
> community support alone does not provide guaranteed response times.

---

Dieses Projekt ist **Open Source und wird durch die Community/den Maintainer
nach dem Best-Effort-Prinzip gepflegt**. Sicherheitsfixes und Weiterentwicklung
erfolgen ueber dieses oeffentliche Repository. Ein **kommerzielles SLA besteht
nicht**, sofern nicht separat schriftlich vereinbart. Da das Projekt unter einer
Open-Source-Lizenz steht, kann jede Organisation den Code zusaetzlich forken,
pruefen und selbst pflegen, um interne Nachweispflichten zu erfuellen.

## Supported versions / Unterstuetzte Versionen

Security updates are provided for the **latest released minor version**. Older
versions receive fixes only at the maintainer's discretion.

| Version | Supported          |
| ------- | ------------------ |
| 1.7.x   | :white_check_mark: |
| < 1.7   | :x:                |

Always run the most recent release. See the
[releases page](https://github.com/BetaHydri/CrossForestOfflineJoin/releases).

## Reporting a vulnerability / Schwachstelle melden

**Please do not open a public issue for security vulnerabilities.**

Use one of the following private channels:

1. **GitHub Security Advisories (preferred):** Go to the repository's
   **Security** tab -> **Report a vulnerability** (private vulnerability
   reporting). This keeps the report confidential until a fix is published.
2. **Direct contact:** Reach the maintainer via the profile on
   [github.com/BetaHydri](https://github.com/BetaHydri).

Please include:

- Affected version / commit and component (e.g. web service, delegation script).
- A clear description and, if possible, reproduction steps or a proof of concept.
- The potential impact (e.g. privilege escalation, information disclosure).

## Response process / Reaktionsprozess

Best-effort targets (no contractual guarantee):

| Stage                          | Target (best effort) |
| ------------------------------ | -------------------- |
| Acknowledge report             | within 5 business days |
| Initial assessment / triage    | within 10 business days |
| Fix or mitigation for critical | as soon as practicable |

Once a fix is available it is published as a new release, referenced in
[CHANGELOG.md](CHANGELOG.md), and — where appropriate — documented in a GitHub
Security Advisory with a CVE identifier requested via GitHub.

## Coordinated disclosure / Koordinierte Offenlegung

We follow coordinated (responsible) disclosure. Please give the maintainer a
reasonable opportunity to publish a fix before disclosing details publicly.
Reporters who wish to be credited will be acknowledged in the advisory and/or
release notes.
