#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Delegates to a foreign-forest identity the right to create computer
    accounts and reset passwords in a target OU.

.DESCRIPTION
    This script is run IN THE RESPECTIVE RESOURCE FOREST (target forest).
    It sets the access control list (ACL) of the target OU so that the
    specified identity (the gMSA of the ODJ service from the Admin-AD forest)
    receives the minimum rights required for "djoin /provision":

      - Create computer objects (Create Child: computer)
      - Reset Password on descendant computer objects
      - Write account restrictions / DNS host name / SPN

    A (at least incoming) forest trust from the target forest to the Admin-AD
    forest is required so that the foreign identity can be resolved.

    Least privilege: only the target OU is delegated, not the whole domain.

.PARAMETER TargetOU
    DistinguishedName of the target OU in the resource forest.

.PARAMETER TrusteeSamAccountName
    Foreign identity in the format 'ADMIN-AD\gmsa-odjsvc$'.

.EXAMPLE
    .\Set-CrossForestOuDelegation.ps1 -TargetOU 'OU=Server,DC=res-a,DC=example,DC=com' -TrusteeSamAccountName 'ADMIN-AD\gmsa-odjsvc$'

.NOTES
    Author: Jan Tiedemann
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $TargetOU,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $TrusteeSamAccountName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Well-known schema GUIDs
$guidComputerClass = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # computer
$guidResetPassword = [guid]'00299570-246d-11d0-a768-00aa006e0529' # extended right: Reset Password
$guidAllProperties = [guid]'00000000-0000-0000-0000-000000000000' # all

# Resolve the foreign principal (requires the trust + name resolution).
$account = New-Object System.Security.Principal.NTAccount($TrusteeSamAccountName)
$sid = $account.Translate([System.Security.Principal.SecurityIdentifier])

$ouPath = "AD:\$TargetOU"
if (-not (Test-Path -LiteralPath $ouPath))
{
    throw "Target OU '$TargetOU' was not found."
}

$acl = Get-Acl -Path $ouPath

# 1) Create/Delete computer child on the OU itself.
$aceCreate = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    [System.DirectoryServices.ActiveDirectoryRights]::CreateChild -bor [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild,
    [System.Security.AccessControl.AccessControlType]::Allow,
    $guidComputerClass,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
)

# 2) Reset password on descendant computer objects.
$aceReset = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
    [System.Security.AccessControl.AccessControlType]::Allow,
    $guidResetPassword,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
    $guidComputerClass
)

# 3) Write all properties on descendant computer objects
#    (covers dNSHostName, servicePrincipalName, userAccountControl).
$aceWrite = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
    [System.Security.AccessControl.AccessControlType]::Allow,
    $guidAllProperties,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
    $guidComputerClass
)

$acl.AddAccessRule($aceCreate)
$acl.AddAccessRule($aceReset)
$acl.AddAccessRule($aceWrite)

if ($PSCmdlet.ShouldProcess($TargetOU, "Set delegation for '$TrusteeSamAccountName'"))
{
    Set-Acl -Path $ouPath -AclObject $acl
    Write-Host "Delegation for '$TrusteeSamAccountName' set on '$TargetOU'." -ForegroundColor Green
}
