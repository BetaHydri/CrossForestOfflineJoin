# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.3] - 2026-07-22

### Fixed

- `scripts/Set-CrossForestOuDelegation.ps1`: the combined `CreateChild -bor
  DeleteChild` right in the first ACE was parsed as `($sid, CreateChild) -bor
  DeleteChild` because the comma bound tighter than `-bor`, so the constructor
  argument became an `[Object[]]` and threw "Method invocation failed because
  [System.Object[]] does not contain a method named 'op_BitwiseOr'." once the
  delegation actually ran. Wrapped the `-bor` expression in parentheses. (This
  line was never reached before v1.6.2 because the bind failed first.)

## [1.6.2] - 2026-07-22

### Changed

- `scripts/Set-CrossForestOuDelegation.ps1` now reads and writes the target OU's
  security descriptor with the ActiveDirectory module (`Get-ADObject` /
  `Set-ADObject -Replace @{ nTSecurityDescriptor = ... }`) instead of a raw
  `DirectoryEntry`. `DirectoryEntry.Options` stayed `$null` after binding in the
  cross-domain/credentialed case, so setting `SecurityMasks` threw "The property
  'SecurityMasks' cannot be found on this object." The AD cmdlets follow the
  referral natively via `-Server`/`-Credential`, so cross-domain and
  cross-forest delegation now succeeds.

## [1.6.1] - 2026-07-22

### Fixed

- `scripts/Set-CrossForestOuDelegation.ps1` no longer fails with "The property
  'SecurityMasks' cannot be found on this object." `DirectoryEntry.Options`
  returns `$null` until the entry is bound, so the DACL-only `SecurityMasks` is
  now set *after* forcing the bind (and the security descriptor is reloaded with
  a DACL-scoped `RefreshCache`), letting the cross-domain delegation write the
  ACL successfully.

## [1.6.0] - 2026-07-22

### Added

- `scripts/Set-CrossForestOuDelegation.ps1` gains optional `-Server` and
  `-Credential` parameters so the OU delegation can be applied remotely from the
  Admin-AD host against a child domain or a foreign forest. Each `-Target` entry
  in `install.ps1` may likewise carry optional `Server` and `Credential` keys,
  which are forwarded to the delegation script (and ignored when building
  `AllowedTargets`).
- Documentation: the two-forest lab dry-run walkthrough now shows per-domain
  `Server`/`Credential` on the delegation targets in `docs/schnellstart.md` and
  `docs/quickstart.md`.

### Changed

- `scripts/Set-CrossForestOuDelegation.ps1` now binds to the target OU through a
  domain-targeted LDAP `DirectoryEntry` instead of the domain-bound `AD:` drive.
  The `AD:` drive resolves only the local host's own domain and raised
  "A referral was returned from the server." for a DistinguishedName in a
  different (child or foreign) domain; the LDAP binding follows the referral
  when a `-Server` of the target domain is supplied.

## [1.5.0] - 2026-07-22

### Added

- `install.ps1` gains a `-CreateWebUiAdminGroup` switch (stage 4b) that creates
  the `WebUiAdminGroup` (default `GG-ODJ-WebAdmins`) as a global security group
  in the service host's domain when it does not exist, mirroring the existing
  `-CreateHostsGroup` behaviour. No members are added automatically; the
  authorised administrators must be added with `Add-ADGroupMember`.
- Documentation: a two-forest lab **dry-run** walkthrough (self-signed
  certificate, web service + web UI, API key, `-WhatIf`) in
  `docs/schnellstart.md` and `docs/quickstart.md`.

## [1.4.0] - 2026-07-22

### Added

- **Structured, injection-safe audit logging (BSI OPS.1.1.5).** New
  `src/WebService/OfflineJoinLogging.ps1` provides a pure line formatter
  (`Format-OdjAuditEvent`) and a writer (`Write-OdjAuditEvent`) that appends an
  ISO-8601 UTC `key=value` record to the file log and, optionally, mirrors it to
  the Windows Event Log. Every value is sanitized (CR/LF/TAB collapsed to a
  single space) so crafted input cannot forge audit lines. The service now logs
  successful **and** failed API-key authentication, all ALLOW/DENY/ERROR
  decisions (API + web UI), and service start/stop — each with the source IP
  (including `X-Forwarded-For`), the caller/user and the target; no secret
  content is ever logged.
- Optional **Windows Event Log** mirror configured via a new `Logging.EventLog`
  block in `appsettings.psd1` (`Enabled`, `LogName`, `Source`) for central
  collection through Windows Event Forwarding / SIEM. Events carry numbered
  categories (Authentication = 1, Provisioning = 2, Service = 3).
- `install.ps1` gains `-EnableEventLog`, `-EventLogName` and `-EventLogSource`;
  it registers the event source once (elevated, `New-EventLog`, guarded by
  `SourceExists`) and writes the `Logging` block into the generated config.
- Unit tests `tests/Unit/OfflineJoinLogging.Tests.ps1` covering the formatter,
  the token sanitizer (log-injection), the event-category mapper, the client
  address helper and the file writer.
- Folder index READMEs: `docs/README.md` (table of the documentation files) and
  `src/README.md` (table of the source module and web service), rendered by
  GitHub as the folder landing pages.
- Dynamic **latest-release badge** (shields.io) plus license and PowerShell
  version badges at the top of both READMEs; the release badge auto-updates and
  links to the releases page.
- **VMware Aria Automation (vRA) / Aria Automation Orchestrator (vRO)**
  integration section and reference links (Broadcom TechDocs) in both READMEs,
  describing the `POST /api/v1/provision` -> `guestinfo` -> first-boot flow.
- **BSI IT-Grundschutz (Germany / public sector)** section in both READMEs: a
  mapping table of the implemented security measures to the currently applicable
  IT-Grundschutz building blocks (Edition 2023) — APP.2.2, ORP.4, APP.3.1,
  CON.1, OPS.1.1.5, CON.8, SYS.1.1 — a shared-responsibility note, and reference
  links to the BSI IT-Grundschutz-Kompendium and building blocks. Documents that
  the solution was developed in line with the currently applicable BSI
  IT-Grundschutz guidelines.

### Changed

- Clarified in both READMEs that the solution is **platform-independent**:
  VMware `guestinfo` is only one blob-delivery option; any platform that can
  request the blob (REST/CLI) and deliver it to the target works (Hyper-V,
  Nutanix, Proxmox/KVM, physical/MDT/SCCM, cloud VMs, Packer/Terraform/Ansible,
  cloud-init/unattend.xml). The provisioning step is worded platform-neutrally.
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

[Unreleased]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.6.3...HEAD
[1.6.3]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.6.2...v1.6.3
[1.6.2]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/releases/tag/v1.0.0
