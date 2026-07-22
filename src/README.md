# Quellcode / Source

Index des Quellcodes von **CrossForestOfflineJoin**. Zur Projektuebersicht siehe
die Haupt-README: [../README.md](../README.md) (Deutsch) &middot;
[../docs/README.en.md](../docs/README.en.md) (English).

## Struktur / Structure

| Pfad / Path | Typ / Type | Inhalt / Content |
|-------------|------------|------------------|
| [OfflineJoin/](OfflineJoin/) | PowerShell-Modul / module | Kernmodul: kapselt `djoin` (Eingabevalidierung, Blob-Erzeugung, unattend-Fragment). |
| [WebService/](WebService/) | Pode-Dienst / service | REST-Dienst und optionale Web-UI (siehe unten). |

### OfflineJoin/ (Kernmodul / core module)

| Datei / File | Zweck / Purpose |
|--------------|-----------------|
| [OfflineJoin/OfflineJoin.psd1](OfflineJoin/OfflineJoin.psd1) | Modul-Manifest: Metadaten, `ModuleVersion`, exportierte Funktionen. |
| [OfflineJoin/OfflineJoin.psm1](OfflineJoin/OfflineJoin.psm1) | Funktionen: `Test-OdjMachineName`, `Test-OdjDistinguishedName`, `New-OfflineDomainJoinBlob`, `ConvertTo-OdjUnattendXml`. |

### WebService/ (REST-Dienst + Web-UI)

| Datei / File | Zweck / Purpose |
|--------------|-----------------|
| [WebService/Start-OfflineJoinService.ps1](WebService/Start-OfflineJoinService.ps1) | Pode-REST-Dienst `POST /api/v1/provision` (TLS, API-Key, Allow-List, Audit) plus optionale Web-UI `GET /ui`. |
| [WebService/OfflineJoinWebUi.ps1](WebService/OfflineJoinWebUi.ps1) | HTML-Bausteine der Web-UI (getrennt, damit unabhaengig testbar; HTML-Encoding gegen XSS). |
| [WebService/OfflineJoinLogging.ps1](WebService/OfflineJoinLogging.ps1) | Strukturierte, injektionssichere Audit-Protokollierung (BSI OPS.1.1.5): Datei-Log plus optionaler Windows-Event-Log-Spiegel. |
| [WebService/appsettings.psd1](WebService/appsettings.psd1) | Konfiguration: Endpunkt, API-Client-Hashes, Positivliste, Auditpfad, `WebUi`-Block, optionaler `Logging`/`EventLog`-Block. |

## Verwandtes / Related

- Skripte / scripts: [../scripts/](../scripts/)
- Tests (Pester 5): [../tests/](../tests/)
- Installer: [../install.ps1](../install.ps1)
