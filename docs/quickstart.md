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

Adjust `src/WebService/appsettings.psd1`:

- `Endpoint.CertificateThumbprint`: thumbprint of the TLS certificate.
- `ApiClients[].ApiKeySha256`: SHA256 hash of the API key (not the clear text).
  Create the hash with:

  ```powershell
  [BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
      [Text.Encoding]::UTF8.GetBytes('MY-API-KEY'))).Replace('-','').ToLower()
  ```

- `AllowedTargets`: allow-list of permitted combinations of domain, target OU
  and name prefix.

## 6. Start the web service

For testing, interactively:

```powershell
.\src\WebService\Start-OfflineJoinService.ps1
```

For production, register it as a **Windows service under the gMSA** (e.g. with
`nssm`) so the service runs permanently under the delegated identity.

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

## See Also

- [README.en.md](README.en.md)
- [schnellstart.md](schnellstart.md) (German)
- [solution-variants.md](solution-variants.md)
- [Microsoft Learn: Offline Domain Join (djoin)](https://learn.microsoft.com/windows-server/identity/ad-ds/deploy/offline-domain-join--djoin--step-by-step)
