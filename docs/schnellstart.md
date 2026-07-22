# Schnellstart: Offline Domain Join Service

Author: Jan Tiedemann

> Sprachen / Languages: **Deutsch** (diese Datei) &middot; [English](quickstart.md)

Diese Anleitung fuehrt Schritt fuer Schritt zur **empfohlenen Zielarchitektur**:
Offline Domain Join (djoin) gekapselt in einem **gMSA-Webdienst**. Damit werden
neue VMware-VMs ohne Double-Hop-Problem und ohne Anmeldeinformationen auf der
Ziel-VM in mehrere Ressourcen-Forests aufgenommen.

> **Automatisierte Installation:** Das Repository enthaelt `install.ps1`, einen
> wiederholt ausfuehrbaren Installer, der die folgenden Schritte automatisiert
> (Voraussetzungspruefung, Pode-Installation, KDS-Root-Key, Hostgruppe,
> gMSA-Erstellung/-Installation, OU-Delegierung, Erzeugung von
> `appsettings.local.psd1` und Dienstregistrierung via `nssm`). Fuer die
> Parameter `Get-Help .\install.ps1 -Full` ausfuehren, oder die manuellen
> Schritte unten lesen, um die Funktionsweise zu verstehen. Der Installer
> unterstuetzt `-WhatIf` fuer einen Probelauf.

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

  [Pode](https://badgerati.github.io/Pode/) ist ein plattformuebergreifendes
  Webserver-Framework in reinem PowerShell. Dieses Projekt nutzt es, um den
  REST-Endpunkt `POST /api/v1/provision` bereitzustellen — inklusive
  HTTPS/TLS-Listener, der `X-Api-Key`-Header-Authentifizierung, dem
  Request-Routing und den JSON-Antworten — dadurch werden weder IIS noch ein
  externer Webserver benoetigt. Pode wird ueber die PowerShell Gallery verteilt;
  die Installation mit `-Scope AllUsers` macht es der gMSA-Dienstidentitaet
  verfuegbar (dafuer ist eine PowerShell-Sitzung mit erhoehten Rechten
  erforderlich).

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

Der Dienst liest alle Einstellungen aus `src/WebService/appsettings.psd1`
(eine PowerShell-Datendatei). Standardmaessig wird die Datei neben
`Start-OfflineJoinService.ps1` verwendet; mit `-ConfigPath` kann eine andere
Datei uebergeben werden. Nach einer Aenderung den Dienst neu starten.

> Tipp: Geheimnisse und umgebungsspezifische Werte aus der Versionsverwaltung
> heraushalten, indem die Datei nach `appsettings.local.psd1` kopiert wird
> (bereits git-ignoriert) und der Dienst mit
> `-ConfigPath .\appsettings.local.psd1` gestartet wird.

### Konfigurationsreferenz

| Einstellung | Bedeutung | Hinweise |
| --- | --- | --- |
| `Endpoint.Address` | Lauschadresse des HTTPS-Listeners. | `'*'` = alle Schnittstellen; oder eine bestimmte IP/Hostname. |
| `Endpoint.Port` | TCP-Port fuer HTTPS. | Standard `8443`. In der Firewall freigeben. |
| `Endpoint.CertificateThumbprint` | Thumbprint des TLS-Serverzertifikats. | Zertifikat muss in `LocalMachine\My` liegen. |
| `ApiClients[]` | Liste zugelassener API-Aufrufer. | Ein Eintrag je Anforderer (z. B. je Automatisierungssystem). |
| `ApiClients[].Name` | Anzeigename des Aufrufers. | Erscheint im Audit-Log. |
| `ApiClients[].ApiKeySha256` | SHA256-Hash des API-Schluessels des Aufrufers. | Niemals den Klartext-Schluessel speichern. |
| `AllowedTargets[]` | Positivliste der erlaubten Provisionierungsziele. | Siehe unten — steuert Domain, OU und Namenspraefix. |
| `AllowedTargets[].Domain` | FQDN der Zieldomaene. | Muss zum Feld `domain` der Anfrage passen. |
| `AllowedTargets[].MachineOU` | Distinguished Name der OU, in der das Computerobjekt angelegt wird. | Die gMSA muss auf dieser OU delegiert sein (Schritt 4). |
| `AllowedTargets[].NamePrefix` | Erforderliches Praefix des Computernamens. | Eine Anfrage ist nur erlaubt, wenn `machineName` mit diesem Praefix beginnt. |
| `AuditLogPath` | Pfad der Audit-Log-Datei. | Das Verzeichnis wird automatisch erstellt. Es werden keine Blob-/Geheimnisinhalte protokolliert. |

### API-Schlussel-Hash

`ApiClients[].ApiKeySha256` enthaelt den SHA256-Hash des API-Schluessels, nicht
den Klartext. Hash erzeugen mit:

```powershell
[BitConverter]::ToString(
  [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [Text.Encoding]::UTF8.GetBytes('MEIN-API-KEY'))).Replace('-','').ToLower()
```

Weitere Aufrufer hinzufuegen, indem weitere Eintraege zu `ApiClients`
hinzugefuegt werden — jeder mit eigenem `Name` und `ApiKeySha256`.

### Mehrere OUs in derselben Zieldomaene ansprechen

Ja — eine Zieldomaene kann **mehrere Ziel-OUs** verwenden. Jeder
`AllowedTargets`-Eintrag ordnet ein **Namenspraefix** genau einer **OU** zu.
Um Computer in verschiedene OUs derselben Domaene zu leiten, je OU einen
Eintrag hinzufuegen und diese ueber `NamePrefix` unterscheiden. Der Dienst
nimmt den **ersten** Eintrag, dessen `Domain` passt und dessen `NamePrefix` ein
Praefix des angefragten `machineName` ist.

```powershell
AllowedTargets = @(
    # res-a.example.com -> Webserver in die Web-OU
    @{
        Domain     = 'res-a.example.com'
        MachineOU  = 'OU=Web,OU=Server,DC=res-a,DC=example,DC=com'
        NamePrefix = 'RESA-WEB'
    }
    # res-a.example.com -> Datenbankserver in die DB-OU
    @{
        Domain     = 'res-a.example.com'
        MachineOU  = 'OU=DB,OU=Server,DC=res-a,DC=example,DC=com'
        NamePrefix = 'RESA-DB'
    }
    # res-b.example.com -> einzelne OU
    @{
        Domain     = 'res-b.example.com'
        MachineOU  = 'OU=Server,DC=res-b,DC=example,DC=com'
        NamePrefix = 'RESB'
    }
)
```

Mit dem Beispiel oben landet `RESA-WEB01` in der Web-OU und `RESA-DB01` in der
DB-OU von `res-a.example.com`. Die gMSA auf **jeder** aufgelisteten OU
delegieren (Schritt 4 je OU wiederholen). **Eindeutige, ueberschneidungsfreie
Praefixe** verwenden — da der erste Treffer gewinnt, wuerde ein breites Praefix
wie `RESA` spezifischere wie `RESA-DB` verdecken.

## 6. Webdienst starten

Zum Testen interaktiv:

```powershell
.\src\WebService\Start-OfflineJoinService.ps1
```

Fuer den Produktivbetrieb als **Windows-Dienst unter der gMSA** registrieren,
damit der Dienst dauerhaft unter der delegierten Identitaet laeuft.

`nssm` — der [Non-Sucking Service Manager](https://nssm.cc/) — ist ein kleines,
kostenloses Open-Source-Hilfsprogramm, das eine beliebige ausfuehrbare Datei
(hier: `pwsh.exe`/`powershell.exe` mit dem Startskript) in einen echten
Windows-Dienst verwandelt — inklusive konfigurierbarem Anmeldekonto. Windows
kann ein beliebiges Skript nicht von Haus aus als Dienst betreiben, und `nssm`
erlaubt zudem, das Dienstkonto auf eine **gMSA** zu setzen (was das klassische
`sc.exe`/`New-Service` nicht direkt kann). Es ist nicht zwingend — jeder
gleichwertige Wrapper (z. B. eine geplante Aufgabe beim Start oder WinSW)
funktioniert ebenso.

Beispiel (in einer Sitzung mit erhoehten Rechten ausfuehren; `nssm.exe` von
<https://nssm.cc/> herunterladen):

```powershell
$svc  = 'OfflineJoinService'
$repo = 'C:\Apps\CrossForestOfflineJoin'   # Pfad zu diesem Repo auf dem Host

# 1) Dienst anlegen, der das Pode-Startskript ausfuehrt.
nssm install $svc 'pwsh.exe' `
    "-NoProfile -File `"$repo\src\WebService\Start-OfflineJoinService.ps1`""
nssm set $svc AppDirectory $repo

# 2) Unter der gMSA ausfuehren (beachte das abschliessende '$', leeres Kennwort).
nssm set $svc ObjectName 'ADMIN-AD\gmsa-odjsvc$' ''

# 3) Starten.
nssm start $svc
```

Auf dem Host, der den Dienst ausfuehrt, muss die gMSA installiert sein
(`Install-ADServiceAccount`, Schritt 3) und der Host Mitglied von
`GG-ODJ-Hosts` sein.

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

## Hosting-Alternative: Windows Server mit IIS

Da Pode ein selbst-hostender Webserver ist, wird **kein IIS benoetigt** — der
Dienst lauscht selbst auf HTTPS. Wenn im Unternehmen auf IIS standardisiert wird
(zentrale Zertifikatsverwaltung, vorhandenes Logging/WAF/Load-Balancing, Port
443), kann IIS vor Pode geschaltet oder an dessen Stelle verwendet werden. In
jedem Fall laeuft die Provisionierungslogik (`djoin` unter der gMSA) weiterhin
in PowerShell.

### Variante A — IIS als Reverse Proxy vor Pode (empfohlen)

IIS terminiert TLS mit dem Unternehmenszertifikat und leitet Anfragen an den
auf `localhost` gebundenen Pode-Listener weiter. Der Pode-Dienst laeuft
weiterhin als Windows-Dienst unter der gMSA (Schritte 2–6), somit sind **keine
Code-Aenderungen** noetig.

```text
VMware --HTTPS 443--> IIS (Reverse Proxy, TLS) --HTTP 127.0.0.1:8080--> Pode (gMSA)
```

1. Die IIS-Erweiterungen **URL Rewrite** und **Application Request Routing
   (ARR)** installieren, dann den Proxy aktivieren: IIS-Manager -> Serverknoten
   -> *Application Request Routing Cache* -> *Server Proxy Settings* ->
   **Enable proxy** aktivieren.
2. Pode nur an Loopback-HTTP binden (`appsettings.psd1` anpassen):

   ```powershell
   Endpoint = @{
       Address = '127.0.0.1'
       Port    = 8080
       # Protokoll uebernimmt jetzt IIS; Thumbprint leer lassen oder den
       # Endpunkt in Start-OfflineJoinService.ps1 auf HTTP umstellen.
   }
   ```

   > Da Pode nur noch auf Loopback lauscht, uebernimmt IIS das TLS. Den
   > Pode-Port per Firewallregel absichern, damit er aus dem Netz nicht
   > erreichbar ist.
3. Eine IIS-Site mit einer **https-Bindung auf 443** und dem
   Unternehmenszertifikat anlegen.
4. Eine **URL-Rewrite**-Regel hinzufuegen, die alles an Pode weiterleitet
   (`web.config` im Site-Stammverzeichnis):

   ```xml
   <configuration>
     <system.webServer>
       <rewrite>
         <rules>
           <rule name="ProxyToPode" stopProcessing="true">
             <match url="(.*)" />
             <action type="Rewrite" url="http://127.0.0.1:8080/{R:1}" />
           </rule>
         </rules>
       </rewrite>
     </system.webServer>
   </configuration>
   ```

   Der `X-Api-Key`-Header bleibt beim Proxying erhalten, die Authentifizierung
   funktioniert also unveraendert.
5. Optional Logging/WAF an IIS auslagern. Die gMSA-Delegierung verbleibt
   vollstaendig auf dem Pode-Dienst — IIS proxyt nur und beruehrt AD nie.

### Variante B — Native IIS-Anwendung unter der gMSA (ohne Pode)

IIS-Anwendungspools koennen **direkt unter einer gMSA**-Identitaet laufen
(`DOMAIN\gmsa$`, Kennwort leer lassen, *Benutzerprofil laden* nach Bedarf) und
liefern so die delegierte Identitaet fuer `djoin` ohne Pode. IIS kann das
mitgelieferte Pode-Skript jedoch nicht direkt ausfuehren; der Endpunkt wuerde
als echte Web-App gehostet — z. B. als ASP.NET-Core-App oder ein
PowerShell-in-IIS-Host wie
[PowerShell Universal](https://ironmansoftware.com/powershell-universal) — die
dieselben `OfflineJoin`-Modulfunktionen aufruft (`New-OfflineDomainJoinBlob`,
`ConvertTo-OdjUnattendXml`).

Das ist ein groesserer Aufwand, weil Request-Verarbeitung, API-Key-Pruefung,
Positivliste und Audit-Log derzeit im Pode-Skript liegen und im gewaehlten
Framework neu umgesetzt werden muessten. Fuer die meisten Umgebungen ist
**Variante A** einfacher und nutzt den mitgelieferten Code unveraendert.

| Aspekt | Variante A (Reverse Proxy) | Variante B (natives IIS) |
| --- | --- | --- |
| Code-Aenderungen | Keine (nur Konfiguration) | Endpunkt neu umsetzen |
| gMSA-Identitaet | Auf dem Pode-Windows-Dienst | IIS-Anwendungspool-Identitaet |
| TLS / Zertifikatsverwaltung | IIS | IIS |
| Aufwand | Gering | Hoch |

## See Also
