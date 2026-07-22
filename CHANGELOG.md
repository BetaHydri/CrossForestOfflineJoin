# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Dynamic **latest-release badge** (shields.io) plus license and PowerShell
  version badges at the top of both READMEs; the release badge auto-updates and
  links to the releases page.
- **VMware Aria Automation (vRA) / Aria Automation Orchestrator (vRO)**
  integration section and reference links (Broadcom TechDocs) in both READMEs,
  describing the `POST /api/v1/provision` -> `guestinfo` -> first-boot flow.

### Changed

- READMEs (DE + EN) now reflect the installer and the optional web UI: the
  architecture mermaid includes the admin web-UI path; the project structure and
  resource tables list `install.ps1`, `OfflineJoinWebUi.ps1` and `tests/`; and
  the setup/usage/security sections were updated accordingly.

## [1.3.0] - 2026-07-22

### Added

- Optional **secured web UI** for AD admins: a browser form served by the Pode
  service (`GET /ui`) that pre-populates the allowed domain/OU targets in a
  drop-down. Secured for IIS Windows Authentication hosting — restricted to a
  configurable AD group (`WebUi.AdminGroup`) via `Add-PodeAuthIIS`, with an
  anti-CSRF token, server-side re-validation against the allow-list, HTTPS, and
  audit logging of the authenticated Windows user. Disabled by default
  (`WebUi.Enabled`). Documented in both quick-start guides.
- `install.ps1`: new `-EnableWebUi`, `-WebUiAdminGroup` and `-WebUiBasePath`
  parameters that write the `WebUi` block into the generated configuration.
- **Pester 5 unit tests** under `tests/Unit/` for the `OfflineJoin` module
  functions and the new web-UI HTML builders (including HTML-encoding/XSS and
  allow-list checks). 45 tests.

### Changed

- Extracted the web-UI HTML builder functions into
  `src/WebService/OfflineJoinWebUi.ps1` (dot-sourced by the service) so they can
  be unit-tested in isolation without starting Pode.

## [1.2.0] - 2026-07-22

### Added

- `install.ps1`: a re-runnable, parameter-driven installer that automates the
  end-to-end setup in up to nine idempotent stages (prerequisite checks, Pode
  install, KDS root key, hosts group, gMSA creation and installation, OU
  delegation, generation of `appsettings.local.psd1`, and registration of the
  Pode web service as a Windows service under the gMSA via `nssm`). Supports
  `-WhatIf`; the API key is supplied as a `SecureString` and only its SHA-256
  hash is written to the configuration. Documented in both quick-start guides.

## [1.1.1] - 2026-07-22

### Changed

- Documentation: clarified what `nssm` is and added a concrete example of
  registering the Pode service as a Windows service under the gMSA, in both
  quick-start guides.
- Documentation: fixed the IIS hosting comparison table (added a header label
  to the first column so it renders correctly), in both quick-start guides.

## [1.1.0] - 2026-07-22

### Added

- Documentation: explanation of the `Pode` module as a prerequisite (what it is
  and why no IIS is required) in both quick-start guides.
- Documentation: full `appsettings.psd1` configuration reference table and a
  guide for targeting multiple OUs in the same destination domain via distinct
  name prefixes, in both quick-start guides.
- Documentation: IIS hosting alternative (IIS as a reverse proxy in front of
  Pode, and a native IIS application under the gMSA) in both quick-start guides,
  with a pointer from both READMEs.

## [1.0.0] - 2026-07-22

### Added

- Core PowerShell module `OfflineJoin` wrapping `djoin.exe`:
  `Test-OdjMachineName`, `Test-OdjDistinguishedName`,
  `New-OfflineDomainJoinBlob`, `ConvertTo-OdjUnattendXml`.
- Pode REST web service (`Start-OfflineJoinService.ps1`) exposing
  `POST /api/v1/provision` with TLS, API-key authentication (SHA256 hash),
  target allow-list, input validation and an audit log.
- Operational scripts: `New-OfflineJoinGmsa.ps1` (gMSA creation),
  `Set-CrossForestOuDelegation.ps1` (cross-forest OU delegation),
  `New-OfflineDomainJoinBlob.ps1` (CLI blob creation),
  `Invoke-OfflineDomainJoinRequest.ps1` (offline blob apply on the target VM).
- Bilingual documentation set (German and English): overview READMEs,
  solution-variant analysis with double-hop assessment, and installation
  quick-start guides with all prerequisites.

### Security

- gMSA-based least-privilege service identity; the service acts under its own
  identity, eliminating the double-hop problem by design.
- ODJ blob (containing the machine password) transported over TLS only,
  short-lived, and temporary files are securely wiped.
- CredSSP is explicitly not used.

[Unreleased]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/releases/tag/v1.0.0
