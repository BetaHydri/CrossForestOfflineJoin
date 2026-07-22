# Quick-Start: Offline Domain Join Service

Author: Jan Tiedemann

> Languages / Sprachen: **English** (this file) &middot; [Deutsch](schnellstart.md)

This guide walks step by step to the **recommended target architecture**:
Offline Domain Join (djoin) wrapped in a **gMSA web service**. It joins new
VMware VMs into multiple resource forests without the double-hop problem and
without credentials on the target VM.

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

## See Also
