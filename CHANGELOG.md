# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/releases/tag/v1.0.0
