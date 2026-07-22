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
| `Logging.EventLog.Enabled` | Spiegelt jedes Audit-Ereignis zusaetzlich ins Windows-Ereignisprotokoll. | Standard `$false`. Fuer zentrale Sammlung per Windows Event Forwarding / SIEM auf `$true` setzen. |
| `Logging.EventLog.LogName` | Ereignisprotokoll (Log), in das geschrieben wird. | Standard `'Application'`. |
| `Logging.EventLog.Source` | Ereignisquelle (Source). | Standard `'OfflineJoinService'`. Muss eindeutig sein und darf keinem vorhandenen Log-Namen entsprechen. Die Quelle einmalig **mit erhoehten Rechten** registrieren: `install.ps1 -EnableEventLog` oder `New-EventLog -LogName Application -Source 'OfflineJoinService'`. Ohne Meldungs-Ressourcendatei zeigt die Ereignisanzeige eine numerische Kategorie und einen generischen Hinweis; der vollstaendige Audit-Text bleibt im Ereignis (und im Datei-Log) erhalten. |

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

Wurde der Blob ueber die Ergebnisseite der Web-UI heruntergeladen (eine Datei
`<Computername>.txt`), diese auf das Ziel kopieren und stattdessen ueber den
Pfad anwenden:

```powershell
.\scripts\Invoke-OfflineDomainJoinRequest.ps1 -BlobPath 'C:\Temp\RESA-WEB01.txt'
```

Intern ruft das `djoin /requestODJ /loadfile <Blob> /windowspath C:\Windows
/localos` auf. Fuer das Format **unattend** das heruntergeladene Fragment
`<Computername>-unattend.xml` in die Komponente
`Microsoft-Windows-UnattendedJoin` der Sysprep-/`unattend.xml` einfuegen, damit
es waehrend der OOBE angewandt wird.

Danach neu starten und den Beitritt pruefen (kein DC-Kontakt, keine
Anmeldedaten):

```powershell
systeminfo | Select-String 'Dom'
nltest /sc_query:res-a.example.com
```

Auf einem DC der Zieldomaene pruefen, ob das Computerobjekt in der richtigen OU
gelandet ist:

```powershell
Get-ADComputer 'RESA-WEB01' -Server 'res-a.example.com' |
    Select-Object Name, DistinguishedName
```

Der Blob ist einmalig gueltig und zeitkritisch: auf eine Maschine anwenden,
deren Hostname exakt dem provisionierten Namen entspricht, bevor das
Kontopasswort rotiert.

## Trockentest: Zwei-Forest-Lab mit Self-Signed-Zertifikat

Fuer einen risikofreien Test kannst du die komplette Installation zuerst als
**Trockenlauf** mit `-WhatIf` durchspielen. Der Installer zeigt dann nur die
geplanten Aenderungen an und fasst nichts an. Dieses Beispiel richtet Dienst
**und** Web-UI ein, nutzt ein selbst signiertes Zertifikat und legt die
Web-UI-Admin-Gruppe an.

Annahme fuer das Lab:

- Der Dienst laeuft in der Root-Domaene `forest1.net` (dort liegt die gMSA). Die
  Web-UI nutzt den Standard `WebUi.AuthMode = 'WindowsAd'`, laeuft also
  eigenstaendig ueber HTTPS und fragt nach AD-Anmeldedaten — **kein IIS** ist
  fuer dieses Lab erforderlich.
- Ziel-Domaenen mit je einer `OU=Server` in der Root:
  - `child.forest1.net` (Kind-Domaene im selben Forest, **kein** Trust noetig)
  - `forest2.net` (fremder Forest, ueber den transitiven Forest-Trust)
  - `child.forest2.net` (fremder Forest, ueber denselben Trust)
- Der **transitive Forest-Trust** `forest1.net` <-> `forest2.net` besteht bereits.

### 1. Self-Signed-Zertifikat erzeugen (elevated, auf dem forest1.net-Host)

```powershell
$cert = New-SelfSignedCertificate `
    -Subject 'CN=odj.forest1.net' `
    -DnsName 'odj.forest1.net', 'localhost' `
    -CertStoreLocation 'Cert:\LocalMachine\My' `
    -KeyExportPolicy Exportable `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -KeyAlgorithm RSA -KeyLength 2048 `
    -NotAfter (Get-Date).AddYears(2) `
    -FriendlyName 'OfflineJoinService (Test)'
$thumb = $cert.Thumbprint
"Thumbprint: $thumb"
```

Damit Browser dem Testzertifikat vertrauen, exportierst du es optional und
importierst es auf den Clients unter `LocalMachine\Root`:

```powershell
Export-Certificate -Cert $cert -FilePath 'C:\Temp\odj-forest1.cer' | Out-Null
# Auf dem Client: Import-Certificate -FilePath '\\...\odj-forest1.cer' -CertStoreLocation 'Cert:\LocalMachine\Root'
```

### 2. API-Key als SecureString erfassen

```powershell
$key = Read-Host -AsSecureString 'API-Key fuer den ersten Client'
```

Nur der SHA256-Hash des Keys wird in die Konfiguration geschrieben; der Klartext
wird nie gespeichert.

### 2b. Domaenen-Admin-Credentials je Ziel-Domaene erfassen

Die OU-Delegierung (Stufe 7) schreibt in die `OU=Server` der jeweiligen
Ziel-Domaene. Weil diese OUs in **anderen** Domaenen als der forest1.net-Host
liegen, wird pro Ziel ein Domain Controller (`Server`) plus passende
`Credential` mitgegeben. Damit laeuft die Delegierung remote vom forest1.net-Host
aus, ohne den Fehler "A referral was returned from the server.".

```powershell
$credChild1  = Get-Credential 'CHILD\Administrator'    # child.forest1.net
$credForest2 = Get-Credential 'FOREST2\Administrator'  # forest2.net
$credChild2  = Get-Credential 'CHILD2\Administrator'   # child.forest2.net
```

> Die NetBIOS-Namen (`CHILD`, `FOREST2`, `CHILD2`) an deine Lab-Domaenen
> anpassen. Der Trustee (die gMSA aus `forest1.net`) wird weiterhin ueber den
> Trust aufgeloest; die Credentials gelten nur fuer das ACL-Schreiben in der
> jeweiligen Ziel-Domaene.

### 3. Trockenlauf der Installation (-WhatIf)

```powershell
.\install.ps1 `
    -GmsaName 'gmsa-odjsvc' `
    -GmsaDns  'gmsa-odjsvc.forest1.net' `
    -HostsGroupName 'GG-ODJ-Hosts' -CreateHostsGroup -CreateKdsRootKey -InstallPode `
    -CertificateThumbprint $thumb `
    -ApiClientName 'lab-test-client' -ApiKey $key `
    -Target @{ Domain='child.forest1.net'; MachineOU='OU=Server,DC=child,DC=forest1,DC=net'; NamePrefix='C1'; Server='dc1.child.forest1.net'; Credential=$credChild1 }, `
            @{ Domain='forest2.net';       MachineOU='OU=Server,DC=forest2,DC=net';           NamePrefix='F2'; Server='dc1.forest2.net';       Credential=$credForest2 }, `
            @{ Domain='child.forest2.net'; MachineOU='OU=Server,DC=child,DC=forest2,DC=net'; NamePrefix='C2'; Server='dc1.child.forest2.net'; Credential=$credChild2 } `
    -SetOuDelegation `
    -EnableWebUi -WebUiAdminGroup 'GG-ODJ-WebAdmins' -CreateWebUiAdminGroup -WebUiBasePath '/ui' `
    -EnableEventLog `
    -WhatIf
```

Hinweise:

- `-WhatIf` = Trockenlauf: keine Aenderung, nur Vorschau. Zum echten Installieren
  denselben Aufruf **ohne** `-WhatIf` erneut ausfuehren.
- Die `NamePrefix`-Werte (`C1`, `F2`, `C2`) sind frei waehlbar und begrenzen die
  erlaubten Computernamen je Ziel.
- `Server`/`Credential` sind pro Ziel **optional**. `child.forest1.net` ist eine
  Kind-Domaene im selben Forest; `forest2.net` und `child.forest2.net` werden
  ueber den bestehenden Forest-Trust erreicht. In allen drei Faellen liegt die
  Ziel-OU in einer anderen Domaene als der forest1.net-Host, daher werden je
  `Server` (ein DC der Ziel-Domaene) und `Credential` mitgegeben.
- `Server`/`Credential` werden nur an `Set-CrossForestOuDelegation.ps1`
  weitergereicht; in die Konfiguration (`AllowedTargets`) fliessen nur `Domain`,
  `MachineOU` und `NamePrefix`.
- Ohne `Server`/`Credential` muss die OU-Delegierung (`-SetOuDelegation`,
  Stufe 7) mit Schreibrechten in der jeweiligen Ziel-Domaene laufen. Ist das vom
  forest1.net-Host aus nicht moeglich, fuehre
  `scripts/Set-CrossForestOuDelegation.ps1` separat auf einem DC der jeweiligen
  Domaene aus.
- Nur die Konfiguration testen (ohne AD-Stufen): denselben Aufruf ohne
  `-GmsaName`, `-CreateHostsGroup`, `-CreateKdsRootKey`, `-SetOuDelegation` und
  `-CreateWebUiAdminGroup` verwenden.

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

## Web UI fuer AD-Administratoren

Zusaetzlich zur Maschine-zu-Maschine-API kann der Dienst ein optionales,
abgesichertes **Browserformular** bereitstellen, mit dem AD-Administratoren
einen Offline-Domain-Join-Blob interaktiv erzeugen — ohne API-Schluessel oder
Skripting. Standardmaessig ist es **deaktiviert**.

### Sicherheitsmodell

- **Zwei Authentifizierungsmodi (`WebUi.AuthMode`).** Das Formular
  authentifiziert den Browser auf eine von zwei Arten gegen Active Directory:
  - `'WindowsAd'` (**Standard**) — der Dienst laeuft eigenstaendig ueber HTTPS.
    Der Dienst zeigt ein gehostetes HTML-Anmeldeformular; die uebermittelten
    AD-Anmeldedaten prueft Pode direkt gegen Active Directory
    (`Add-PodeAuthWindowsAd`) ueber den bestehenden TLS-Kanal, gesichert durch
    ein serverseitiges Sitzungscookie. **Kein IIS erforderlich** - `/ui`
    funktioniert sofort auf einem selbst gehosteten Pode-Dienst.
  - `'IIS'` — der Dienst laeuft hinter IIS mit aktivierter
    Windows-Authentifizierung (siehe *Hosting-Alternative: Windows Server mit
    IIS*, Variante A). Das ASP.NET-Core-Modul von IIS reicht die
    Windows-Identitaet des Aufrufers durch (`Add-PodeAuthIIS`) fuer nahtloses
    Kerberos-Single-Sign-on; die Pode-Route vertraut nichts anderem.

  Beide Modi beschraenken den Zugriff auf `WebUi.AdminGroup` und weisen alle
  anderen ab.
- **Gruppenbeschraenkt.** Nur Mitglieder der konfigurierten Admin-Gruppe
  (`WebUi.AdminGroup`, Standard `GG-ODJ-WebAdmins`) duerfen das Formular
  oeffnen. Die Gruppe muss bereits existieren; der Installer legt sie auf
  Wunsch mit `-CreateWebUiAdminGroup` an (Mitglieder danach selbst per
  `Add-ADGroupMember` aufnehmen).
- **Serverseitige Validierung.** Jede Anfrage wird erneut gegen
  `AllowedTargets` geprueft; der Browser sendet nur einen *Zielindex*, niemals
  eine rohe Domaene oder OU. Computernamen werden wie an der API validiert.
- **Anti-CSRF.** Jede Formularausgabe enthaelt ein sitzungsgebundenes Token,
  das beim Absenden zurueckgegeben werden muss (Pode-Session-Middleware).
- **Auditiert.** Formularaktionen werden als `ALLOW-UI`-, `DENY-UI`- und
  `ERROR-UI`-Zeilen protokolliert (kein Blob-Inhalt wird geloggt).

### Aktivieren

Bei der Installation die Web-UI-Schalter ergaenzen:

```powershell
.\install.ps1 `
    -CertificateThumbprint 'ABCD...1234' `
    -ApiClientName 'aria' -ApiKey $key `
    -Target @{ Domain='res-a.example.com'; MachineOU='OU=Server,DC=res-a,DC=example,DC=com'; NamePrefix='RESA' } `
    -EnableWebUi -WebUiAdminGroup 'GG-ODJ-WebAdmins' -WebUiBasePath '/ui'
```

Existiert die Admin-Gruppe noch nicht, legt der Installer sie mit
`-CreateWebUiAdminGroup` als globale Sicherheitsgruppe an (danach die
berechtigten Administratoren per `Add-ADGroupMember` hinzufuegen).

```powershell
WebUi = @{
    Enabled    = $true
    AuthMode   = 'WindowsAd'   # 'WindowsAd' (Standard, eigenstaendig) oder 'IIS'
    AdminGroup = 'GG-ODJ-WebAdmins'
    BasePath   = '/ui'
}
```

### Verwenden

1. `https://<Dienst-Host>/ui` (oder eigener `BasePath`) im Browser oeffnen. Im
   Standardmodus `WindowsAd` zeigt der Dienst ein gehostetes
   HTML-Anmeldeformular fuer AD-Anmeldedaten; im Modus `IIS` fragt IIS nach
   Windows-Anmeldedaten. In beiden Faellen werden Nicht-Mitglieder der
   Admin-Gruppe abgewiesen.
2. Computernamen eingeben, ein Ziel aus dem Dropdown (aus `AllowedTargets`
   befuellt) waehlen und das Ausgabeformat waehlen — **blob** (Base64) oder
   **unattend** (XML-Fragment).
3. Absenden. Die Ergebnisseite zeigt den erzeugten Blob bzw. das Unattend-XML,
   erzeugt ueber denselben `New-OfflineDomainJoinBlob`- /
   `ConvertTo-OdjUnattendXml`-Codepfad wie die API. In das Textfeld klicken, um
   den Payload zu kopieren, oder ueber die Schaltflaeche **Download** als Datei
   speichern (`<Computername>.txt` fuer einen Blob, `<Computername>-unattend.xml`
   fuer Unattend-XML).

## See Also
