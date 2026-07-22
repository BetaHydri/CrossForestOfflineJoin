# Schnellstart: Offline Domain Join Service

Author: Jan Tiedemann

> Sprachen / Languages: **Deutsch** (diese Datei) &middot; [English](quickstart.md)

Diese Anleitung fuehrt Schritt fuer Schritt zur **empfohlenen Zielarchitektur**:
Offline Domain Join (djoin) gekapselt in einem **gMSA-Webdienst**. Damit werden
neue VMware-VMs ohne Double-Hop-Problem und ohne Anmeldeinformationen auf der
Ziel-VM in mehrere Ressourcen-Forests aufgenommen.

## 1. Voraussetzungen

### Infrastruktur / Active Directory

- Ein zentraler **Admin-AD-Forest** und ein oder mehrere **Ressourcen-Forests**.
- **Gesamtstruktur-Vertrauensstellungen** (Forest Trusts) vom jeweiligen
  Ressourcen-Forest zum Admin-AD-Forest (mindestens eingehend), damit die
  Fremd-Identitaet (gMSA) aufgeloest werden kann.
- Eine **Ziel-OU** je Ressourcen-Forest, in der die Computerkonten angelegt
  werden (z. B. `OU=Server,DC=res-a,DC=example,DC=com`).
- **KDS-Rootkey** im Admin-AD-Forest (Voraussetzung fuer gMSA). Falls noch nicht
  vorhanden:

  ```powershell
  # In der Produktion 10 Stunden Wartezeit; im Labor sofort wirksam:
  Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
  ```

- Eine **Sicherheitsgruppe** fuer die Hostserver, die das gMSA-Kennwort abrufen
  duerfen (z. B. `GG-ODJ-Hosts`). Die Hostserver dort Mitglied machen.

### Software / Rechte

- **PowerShell 5.1+** auf dem Admin-AD-Server.
- **RSAT-Modul `ActiveDirectory`** (`Get-Module -ListAvailable ActiveDirectory`).
- **`Pode`-Modul** fuer den Webdienst:

  ```powershell
  Install-Module Pode -Scope AllUsers
  ```

- Ein **Server-TLS-Zertifikat** im Speicher `LocalMachine\My` (fuer HTTPS).
  Thumbprint notieren.
- Rechte zum **Erstellen von Dienstkonten** im Admin-AD-Forest und zum **Setzen
  von OU-ACLs** im jeweiligen Ressourcen-Forest.

### Ziel-VM (VMware)

- **VMware Tools** installiert (fuer die `guestinfo`-Variante).
- Zugriff auf die VMware-Automatisierung (Aria/vRO), die die API aufruft und den
  Blob injiziert.

## 2. gMSA im Admin-AD-Forest anlegen

```powershell
.\scripts\New-OfflineJoinGmsa.ps1 `
    -Name 'gmsa-odjsvc' `
    -Dns 'gmsa-odjsvc.admin-ad.example.com' `
    -PrincipalsAllowedToRetrieveManagedPassword 'GG-ODJ-Hosts'
```

## 3. gMSA auf den Hostservern installieren

Auf jedem Server, der den Dienst ausfuehrt:

```powershell
Install-ADServiceAccount -Identity 'gmsa-odjsvc'
Test-ADServiceAccount   -Identity 'gmsa-odjsvc'   # muss True liefern
```

## 4. OU-Delegierung je Ressourcen-Forest setzen

Im jeweiligen **Zielforest** ausfuehren (delegiert der gMSA nur die minimal
noetigen Rechte in der Ziel-OU):

```powershell
.\scripts\Set-CrossForestOuDelegation.ps1 `
    -TargetOU 'OU=Server,DC=res-a,DC=example,DC=com' `
    -TrusteeSamAccountName 'ADMIN-AD\gmsa-odjsvc$'
```

Schritt fuer jeden weiteren Ressourcen-Forest wiederholen.

## 5. Webdienst konfigurieren

`src/WebService/appsettings.psd1` anpassen:

- `Endpoint.CertificateThumbprint`: Thumbprint des TLS-Zertifikats.
- `ApiClients[].ApiKeySha256`: SHA256-Hash des API-Schluessels (nicht der
  Klartext). Hash erzeugen mit:

  ```powershell
  [BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
      [Text.Encoding]::UTF8.GetBytes('MEIN-API-KEY'))).Replace('-','').ToLower()
  ```

- `AllowedTargets`: Positivliste der erlaubten Kombinationen aus Domain, Ziel-OU
  und Namenspraefix.

## 6. Webdienst starten

Zum Testen interaktiv:

```powershell
.\src\WebService\Start-OfflineJoinService.ps1
```

Fuer den Produktivbetrieb als **Windows-Dienst unter der gMSA** registrieren
(z. B. mit `nssm`), damit der Dienst dauerhaft unter der delegierten Identitaet
laeuft.

## 7. Funktion pruefen

Blob per API anfordern:

```powershell
$headers = @{ 'X-Api-Key' = 'MEIN-API-KEY' }
$body = @{ machineName = 'RESA-WEB01'; domain = 'res-a.example.com'; outputFormat = 'blob' } | ConvertTo-Json

Invoke-RestMethod -Method Post `
    -Uri 'https://odjsvc.admin-ad.example.com:8443/api/v1/provision' `
    -Headers $headers -Body $body -ContentType 'application/json'
```

Auf der Ziel-VM (First-Boot) anwenden:

```powershell
.\scripts\Invoke-OfflineDomainJoinRequest.ps1 -GuestInfoKey 'guestinfo.odjblob'
```

## Fehlerbehebung (haeufige Stolpersteine)

- **`Test-ADServiceAccount` liefert False:** Hostserver ist nicht Mitglied der
  Gruppe `GG-ODJ-Hosts`, oder der KDS-Rootkey ist noch nicht wirksam (bis zu 10
  Stunden).
- **Fremd-Principal kann nicht aufgeloest werden:** Forest Trust oder
  Namensaufloesung (DNS) pruefen.
- **`djoin /provision` schlaegt fehl (Access Denied):** OU-Delegierung in Schritt
  4 fehlt oder verweist auf die falsche OU.
- **HTTPS startet nicht:** Zertifikat-Thumbprint falsch oder Zertifikat nicht in
  `LocalMachine\My`.

## Nur-CLI-Alternative (ohne Webdienst)

Fuer Tests oder kleine Umgebungen kann der Blob direkt erzeugt werden — die
Schritte 1 bis 4 (gMSA + Delegierung) sind weiterhin die Grundlage:

```powershell
.\scripts\New-OfflineDomainJoinBlob.ps1 `
    -Domain 'res-a.example.com' `
    -MachineName 'RESA-WEB01' `
    -MachineOU 'OU=Server,DC=res-a,DC=example,DC=com' `
    -OutputFormat Blob
```

## See Also

- [README](../README.md)
- [quickstart.md](quickstart.md) (English)
- [loesungsvarianten.md](loesungsvarianten.md)
- [Microsoft Learn: Offline Domain Join (djoin)](https://learn.microsoft.com/windows-server/identity/ad-ds/deploy/offline-domain-join--djoin--step-by-step)
