# Quick-Start: Offline Domain Join Service

Author: Jan Tiedemann

> Languages / Sprachen: **English** (this file) &middot; [Deutsch](schnellstart.md)

This guide walks step by step to the **recommended target architecture**:
Offline Domain Join (djoin) wrapped in a **gMSA web service**. It joins new
VMware VMs into multiple resource forests without the double-hop problem and
without credentials on the target VM.

> **Automated install:** the repository ships `install.ps1`, a re-runnable
> installer that automates the steps below (prerequisite checks, Pode install,
> KDS root key, hosts group, gMSA creation/installation, OU delegation,
> `appsettings.local.psd1` generation and service registration via `nssm`). Run
> `Get-Help .\install.ps1 -Full` for parameters, or read the manual steps below
> to understand what it does. It supports `-WhatIf` for a dry run.

## 1. Prerequisites

### Infrastructure / Active Directory

- A central **Admin-AD forest** and one or more **resource forests**.
- **Forest trusts** from each resource forest to the Admin-AD forest (at least
  inbound) so the foreign identity (gMSA) can be resolved.
- A **target OU** per resource forest where the computer accounts are created
  (e.g. `OU=Server,DC=res-a,DC=example,DC=com`).
- A **KDS root key** in the Admin-AD forest (required for gMSA). If not present
  yet:

  ```powershell
  # In production wait 10 hours; in a lab it is effective immediately:
  Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
  ```

- A **security group** for the host servers that may retrieve the gMSA password
  (e.g. `GG-ODJ-Hosts`). Make the host servers members.

### Software / permissions

- **PowerShell 5.1+** on the Admin-AD server.
- **RSAT module `ActiveDirectory`** (`Get-Module -ListAvailable ActiveDirectory`).
- **`Pode` module** for the web service:

  ```powershell
  Install-Module Pode -Scope AllUsers
  ```

  [Pode](https://badgerati.github.io/Pode/) is a cross-platform,
  pure-PowerShell web-server framework. This project uses it to host the REST
  endpoint `POST /api/v1/provision` — including the HTTPS/TLS listener, the
  `X-Api-Key` header authentication, request routing and JSON responses — so no
  IIS or external web server is required. It is published on the PowerShell
  Gallery; the `-Scope AllUsers` install makes it available to the gMSA service
  identity (an elevated PowerShell session is required for that scope).

- A **server TLS certificate** in the `LocalMachine\My` store (for HTTPS). Note
  the thumbprint.
- Permissions to **create service accounts** in the Admin-AD forest and to **set
  OU ACLs** in each resource forest.

### Target VM (VMware)

- **VMware Tools** installed (for the `guestinfo` variant).
- Access to the VMware automation (Aria/vRO) that calls the API and injects the
  blob.

## 2. Create the gMSA in the Admin-AD forest

```powershell
.\scripts\New-OfflineJoinGmsa.ps1 `
    -Name 'gmsa-odjsvc' `
    -Dns 'gmsa-odjsvc.admin-ad.example.com' `
    -PrincipalsAllowedToRetrieveManagedPassword 'GG-ODJ-Hosts'
```

## 3. Install the gMSA on the host servers

On each server that runs the service:

```powershell
Install-ADServiceAccount -Identity 'gmsa-odjsvc'
Test-ADServiceAccount   -Identity 'gmsa-odjsvc'   # must return True
```

## 4. Set OU delegation per resource forest

Run in the respective **target forest** (delegates only the minimal required
rights to the gMSA in the target OU):

```powershell
.\scripts\Set-CrossForestOuDelegation.ps1 `
    -TargetOU 'OU=Server,DC=res-a,DC=example,DC=com' `
    -TrusteeSamAccountName 'ADMIN-AD\gmsa-odjsvc$'
```

Repeat for every additional resource forest.

## 5. Configure the web service

The service reads all its settings from `src/WebService/appsettings.psd1`
(a PowerShell data file). By default the file next to
`Start-OfflineJoinService.ps1` is used; a different file can be passed with
`-ConfigPath`. After changing the file, restart the service.

> Tip: keep secrets and environment-specific values out of version control by
> copying the file to `appsettings.local.psd1` (already git-ignored) and
> starting the service with `-ConfigPath .\appsettings.local.psd1`.

### Configuration reference

| Setting | Meaning | Notes |
| --- | --- | --- |
| `Endpoint.Address` | Listen address of the HTTPS listener. | `'*'` = all interfaces; or a specific IP/hostname. |
| `Endpoint.Port` | TCP port for HTTPS. | Default `8443`. Open it in the firewall. |
| `Endpoint.CertificateThumbprint` | Thumbprint of the TLS server certificate. | Certificate must be in `LocalMachine\My`. |
| `ApiClients[]` | List of permitted API callers. | One entry per requester (e.g. per automation system). |
| `ApiClients[].Name` | Friendly name of the caller. | Appears in the audit log. |
| `ApiClients[].ApiKeySha256` | SHA256 hash of the caller's API key. | Never store the clear-text key. |
| `AllowedTargets[]` | Allow-list of permitted provisioning targets. | See below — controls domain, OU and name prefix. |
| `AllowedTargets[].Domain` | FQDN of the destination domain. | Must match the `domain` field in the request. |
| `AllowedTargets[].MachineOU` | Distinguished name of the OU the computer object is created in. | The gMSA must be delegated on this OU (step 4). |
| `AllowedTargets[].NamePrefix` | Required prefix of the computer name. | A request is only allowed if `machineName` starts with this prefix. |
| `AuditLogPath` | Path of the audit log file. | The directory is created automatically. No blob/secret content is logged. |
| `Logging.EventLog.Enabled` | Additionally mirrors every audit event to the Windows Event Log. | Default `$false`. Set to `$true` for central collection via Windows Event Forwarding / SIEM. |
| `Logging.EventLog.LogName` | Event log to write to. | Default `'Application'`. |
| `Logging.EventLog.Source` | Event source. | Default `'OfflineJoinService'`. Must be unique and must not equal an existing log name. Register the source once **with elevated rights**: `install.ps1 -EnableEventLog` or `New-EventLog -LogName Application -Source 'OfflineJoinService'`. Without a message resource file the Event Viewer shows a numeric category and a generic note; the full audit text is still contained in each event (and in the file log). |

### API key hash

`ApiClients[].ApiKeySha256` holds the SHA256 hash of the API key, not the
clear text. Create the hash with:

```powershell
[BitConverter]::ToString(
  [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [Text.Encoding]::UTF8.GetBytes('MY-API-KEY'))).Replace('-','').ToLower()
```

Add more callers by adding further entries to `ApiClients`, each with its own
`Name` and `ApiKeySha256`.

### Targeting multiple OUs in the same destination domain

Yes — a destination domain can use **several target OUs**. Each `AllowedTargets`
entry maps one **name prefix** to exactly one **OU**. To route computers to
different OUs within the same domain, add one entry per OU and distinguish them
by `NamePrefix`. The service picks the **first** entry whose `Domain` matches
and whose `NamePrefix` is a prefix of the requested `machineName`.

```powershell
AllowedTargets = @(
    # res-a.example.com -> web servers into the Web OU
    @{
        Domain     = 'res-a.example.com'
        MachineOU  = 'OU=Web,OU=Server,DC=res-a,DC=example,DC=com'
        NamePrefix = 'RESA-WEB'
    }
    # res-a.example.com -> database servers into the DB OU
    @{
        Domain     = 'res-a.example.com'
        MachineOU  = 'OU=DB,OU=Server,DC=res-a,DC=example,DC=com'
        NamePrefix = 'RESA-DB'
    }
    # res-b.example.com -> single OU
    @{
        Domain     = 'res-b.example.com'
        MachineOU  = 'OU=Server,DC=res-b,DC=example,DC=com'
        NamePrefix = 'RESB'
    }
)
```

With the example above, `RESA-WEB01` lands in the Web OU and `RESA-DB01` in the
DB OU of `res-a.example.com`. Delegate the gMSA on **every** OU you list
(repeat step 4 per OU). Use **distinct, non-overlapping prefixes** — because the
first match wins, a broad prefix like `RESA` would shadow more specific ones
such as `RESA-DB`.

## 6. Start the web service

For testing, interactively:

```powershell
.\src\WebService\Start-OfflineJoinService.ps1
```

For production, register it as a **Windows service under the gMSA** so the
service runs permanently under the delegated identity.

`nssm` — the [Non-Sucking Service Manager](https://nssm.cc/) — is a small,
free open-source helper that turns any executable (here: `pwsh.exe`/
`powershell.exe` running the start script) into a proper Windows service,
including a configurable logon account. Windows has no built-in way to run an
arbitrary script as a service, and `nssm` also lets you set the service logon
to a **gMSA** (which the classic `sc.exe`/`New-Service` cannot do directly). It
is not required — any equivalent wrapper (e.g. a scheduled task at startup, or
WinSW) works too.

Example (run in an elevated shell; download `nssm.exe` from <https://nssm.cc/>):

```powershell
$svc  = 'OfflineJoinService'
$repo = 'C:\Apps\CrossForestOfflineJoin'   # path to this repo on the host

# 1) Create the service that runs the Pode start script.
nssm install $svc 'pwsh.exe' `
    "-NoProfile -File `"$repo\src\WebService\Start-OfflineJoinService.ps1`""
nssm set $svc AppDirectory $repo

# 2) Run it under the gMSA (note the trailing '$', empty password).
nssm set $svc ObjectName 'ADMIN-AD\gmsa-odjsvc$' ''

# 3) Start it.
nssm start $svc
```

The host running the service must have the gMSA installed
(`Install-ADServiceAccount`, step 3) and be a member of `GG-ODJ-Hosts`.

## 7. Verify

Request a blob via the API:

```powershell
$headers = @{ 'X-Api-Key' = 'MY-API-KEY' }
$body = @{ machineName = 'RESA-WEB01'; domain = 'res-a.example.com'; outputFormat = 'blob' } | ConvertTo-Json

Invoke-RestMethod -Method Post `
    -Uri 'https://odjsvc.admin-ad.example.com:8443/api/v1/provision' `
    -Headers $headers -Body $body -ContentType 'application/json'
```

Apply it on the target VM (first boot):

```powershell
.\scripts\Invoke-OfflineDomainJoinRequest.ps1 -GuestInfoKey 'guestinfo.odjblob'
```

## Dry run: two-forest lab with a self-signed certificate

For a risk-free test you can first run the whole installation as a **dry run**
with `-WhatIf`. The installer then only prints the planned changes and touches
nothing. This example sets up the service **and** the web UI, uses a self-signed
certificate and creates the web UI admin group.

Lab assumptions:

- The service runs in the root domain `forest1.net` (that is where the gMSA
  lives and where IIS/Windows resolves the caller identity).
- Target domains, each with an `OU=Server` in its root:
  - `child.forest1.net` (child domain in the same forest, **no** trust needed)
  - `forest2.net` (foreign forest, via the transitive forest trust)
  - `child.forest2.net` (foreign forest, via the same trust)
- The **transitive forest trust** `forest1.net` <-> `forest2.net` already exists.

### 1. Create a self-signed certificate (elevated, on the forest1.net host)

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

So that browsers trust the test certificate, optionally export it and import it
on the clients under `LocalMachine\Root`:

```powershell
Export-Certificate -Cert $cert -FilePath 'C:\Temp\odj-forest1.cer' | Out-Null
# On the client: Import-Certificate -FilePath '\\...\odj-forest1.cer' -CertStoreLocation 'Cert:\LocalMachine\Root'
```

### 2. Capture the API key as a SecureString

```powershell
$key = Read-Host -AsSecureString 'API key for the first client'
```

Only the SHA256 hash of the key is written to the configuration; the clear text
is never stored.

### 2b. Collect a domain-admin credential per target domain

OU delegation (stage 7) writes to the `OU=Server` of each target domain. Because
those OUs live in domains **other** than the forest1.net host, each target is
given a domain controller (`Server`) plus a matching `Credential`. This lets the
delegation run remotely from the forest1.net host without the
"A referral was returned from the server." error.

```powershell
$credChild1  = Get-Credential 'CHILD\Administrator'    # child.forest1.net
$credForest2 = Get-Credential 'FOREST2\Administrator'  # forest2.net
$credChild2  = Get-Credential 'CHILD2\Administrator'   # child.forest2.net
```

> Adjust the NetBIOS names (`CHILD`, `FOREST2`, `CHILD2`) to your lab domains.
> The trustee (the gMSA from `forest1.net`) is still resolved through the trust;
> the credentials only apply to the ACL write in the respective target domain.

### 3. Dry run of the installation (-WhatIf)

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

Notes:

- `-WhatIf` = dry run: no changes, preview only. To install for real, run the
  same command again **without** `-WhatIf`.
- The `NamePrefix` values (`C1`, `F2`, `C2`) are free to choose and constrain the
  allowed computer names per target.
- `Server`/`Credential` are **optional** per target. `child.forest1.net` is a
  child domain in the same forest; `forest2.net` and `child.forest2.net` are
  reached via the existing forest trust. In all three cases the target OU lives
  in a domain other than the forest1.net host, so each is given a `Server` (a DC
  of the target domain) and a `Credential`.
- `Server`/`Credential` are only forwarded to
  `scripts/Set-CrossForestOuDelegation.ps1`; only `Domain`, `MachineOU` and
  `NamePrefix` flow into the configuration (`AllowedTargets`).
- Without `Server`/`Credential`, OU delegation (`-SetOuDelegation`, stage 7) must
  run with write rights in the respective target domain. If this is not possible
  from the forest1.net host, run `scripts/Set-CrossForestOuDelegation.ps1`
  separately on a DC of the respective domain.
- To test only the configuration (without the AD stages), use the same command
  without `-GmsaName`, `-CreateHostsGroup`, `-CreateKdsRootKey`,
  `-SetOuDelegation` and `-CreateWebUiAdminGroup`.

## Troubleshooting (common pitfalls)

- **`Test-ADServiceAccount` returns False:** the host server is not a member of
  `GG-ODJ-Hosts`, or the KDS root key is not effective yet (up to 10 hours).
- **Foreign principal cannot be resolved:** check the forest trust and name
  resolution (DNS).
- **`djoin /provision` fails (Access Denied):** the OU delegation from step 4 is
  missing or points to the wrong OU.
- **HTTPS does not start:** wrong certificate thumbprint or the certificate is
  not in `LocalMachine\My`.

## CLI-only alternative (without the web service)

For tests or small environments the blob can be created directly — steps 1 to 4
(gMSA + delegation) remain the foundation:

```powershell
.\scripts\New-OfflineDomainJoinBlob.ps1 `
    -Domain 'res-a.example.com' `
    -MachineName 'RESA-WEB01' `
    -MachineOU 'OU=Server,DC=res-a,DC=example,DC=com' `
    -OutputFormat Blob
```

## Hosting alternative: Windows Server with IIS

Because Pode is a self-hosted web server, **IIS is not required** — the service
listens on HTTPS on its own. If your organization standardizes on IIS (central
certificate management, existing logging/WAF/load balancing, port 443), you can
put IIS in front of, or in place of, Pode. Whichever option you pick, the
provisioning logic (`djoin` under the gMSA) still runs in PowerShell.

### Option A — IIS as a reverse proxy in front of Pode (recommended)

IIS terminates TLS with the corporate certificate and forwards requests to the
Pode listener bound to `localhost`. The Pode service keeps running as a Windows
service under the gMSA (steps 2–6), so **no code changes** are needed.

```text
VMware --HTTPS 443--> IIS (reverse proxy, TLS) --HTTP 127.0.0.1:8080--> Pode (gMSA)
```

1. Install the **URL Rewrite** and **Application Request Routing (ARR)** IIS
   extensions, then enable the proxy: IIS Manager -> server node ->
   *Application Request Routing Cache* -> *Server Proxy Settings* ->
   check **Enable proxy**.
2. Bind Pode to loopback HTTP only (edit `appsettings.psd1`):

   ```powershell
   Endpoint = @{
       Address = '127.0.0.1'
       Port    = 8080
       # Protocol is handled by IIS now; keep the thumbprint empty or
       # switch the endpoint to HTTP in Start-OfflineJoinService.ps1.
   }
   ```

   > Because Pode now only listens on loopback, TLS is handled by IIS. Restrict
   > the Pode port with a firewall rule so it is not reachable from the network.
3. Create an IIS site with an **https binding on 443** using the corporate
   certificate.
4. Add a **URL Rewrite** rule that forwards everything to Pode (`web.config`
   in the site root):

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

   The `X-Api-Key` header is preserved by the proxy, so authentication keeps
   working unchanged.
5. Optionally offload logging/WAF to IIS. The gMSA delegation stays entirely on
   the Pode service — IIS only proxies and never touches AD.

### Option B — Native IIS application under the gMSA (no Pode)

IIS Application Pools can run **directly under a gMSA** identity
(`DOMAIN\gmsa$`, leave the password blank, set *Load User Profile* as needed),
which provides the delegated identity for `djoin` without Pode. IIS, however,
cannot execute the shipped Pode script directly; you would host the endpoint as
a proper web app — e.g. an ASP.NET Core app or a PowerShell-in-IIS host such as
[PowerShell Universal](https://ironmansoftware.com/powershell-universal) — that
calls the same `OfflineJoin` module functions (`New-OfflineDomainJoinBlob`,
`ConvertTo-OdjUnattendXml`).

This is a larger engineering effort because the request handling, API-key check,
allow-list and audit logging currently live in the Pode script and would need to
be re-implemented in the chosen framework. For most deployments **Option A** is
simpler and reuses the shipped code as-is.

| Aspect | Option A (reverse proxy) | Option B (native IIS) |
| --- | --- | --- |
| Code changes | None (config only) | Re-implement the endpoint |
| gMSA identity | On the Pode Windows service | IIS Application Pool identity |
| TLS / cert management | IIS | IIS |
| Effort | Low | High |

## Web UI for AD admins

In addition to the machine-to-machine API, the service can expose an optional
secured **browser form** so AD admins can generate an offline domain join blob
interactively — no API key or scripting required. It is **disabled by default**.

### Security model

- **Windows Authentication via IIS.** The form is only usable when the service
  is hosted behind IIS with Windows Authentication enabled (see *Hosting
  alternative: Windows Server with IIS*, Option A). IIS forwards the caller's
  Windows identity; the Pode route trusts nothing else.
- **Group-restricted.** Only members of the configured admin group
  (`WebUi.AdminGroup`, default `GG-ODJ-WebAdmins`) may open the form. The group
  must already exist; the installer can create it on request with
  `-CreateWebUiAdminGroup` (add the members yourself with `Add-ADGroupMember`).
- **Server-side validation.** Every request is re-validated against
  `AllowedTargets`; the browser only submits a *target index*, never a raw
  domain or OU. Computer names are validated the same way as on the API.
- **Anti-CSRF.** Each form render embeds a per-session token that must be
  echoed on submit, backed by Pode session middleware.
- **Audited.** Form actions are written to the audit log as `ALLOW-UI`,
  `DENY-UI` and `ERROR-UI` lines (no blob content is logged).

### Enable it

During install, add the Web UI switches:

```powershell
.\install.ps1 `
    -CertificateThumbprint 'ABCD...1234' `
    -ApiClientName 'aria' -ApiKey $key `
    -Target @{ Domain='res-a.example.com'; MachineOU='OU=Server,DC=res-a,DC=example,DC=com'; NamePrefix='RESA' } `
    -EnableWebUi -WebUiAdminGroup 'GG-ODJ-WebAdmins' -WebUiBasePath '/ui'
```

If the admin group does not exist yet, the installer creates it with
`-CreateWebUiAdminGroup` as a global security group (then add the authorised
administrators with `Add-ADGroupMember`).

```powershell
WebUi = @{
    Enabled    = $true
    AdminGroup = 'GG-ODJ-WebAdmins'
    BasePath   = '/ui'
}
```

### Use it

1. Browse to `https://<service-host>/ui` (or your custom `BasePath`). IIS
   prompts for Windows credentials; non-members of the admin group are rejected.
2. Enter the computer name, pick a target from the drop-down (populated from
   `AllowedTargets`) and choose the output format — **blob** (Base64) or
   **unattend** (XML fragment).
3. Submit. The result page shows the generated blob or unattend XML, produced
   by the same `New-OfflineDomainJoinBlob` / `ConvertTo-OdjUnattendXml` code
   path used by the API.

## See Also
