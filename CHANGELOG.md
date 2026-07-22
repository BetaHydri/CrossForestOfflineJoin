# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/BetaHydri/CrossForestOfflineJoin/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/BetaHydri/CrossForestOfflineJoin/releases/tag/v1.0.0
