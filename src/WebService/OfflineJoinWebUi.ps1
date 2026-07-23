#Requires -Version 5.1

<#
.SYNOPSIS
    Pure HTML builder functions for the Offline Domain Join web UI.

.DESCRIPTION
    These functions produce the HTML for the optional browser form served by
    Start-OfflineJoinService.ps1. They contain no Pode or Active Directory
    dependencies, so they can be dot-sourced and unit-tested in isolation.
    All caller-provided values are HTML-encoded to prevent XSS.

.NOTES
    Author: Jan Tiedemann
#>

function Get-OdjHtmlPage
{
    <#
    .SYNOPSIS
        Wraps a body fragment in the shared HTML page shell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $Title,

        [Parameter(Mandatory)]
        [string]
        $Body
    )

    $titleEnc = [System.Net.WebUtility]::HtmlEncode($Title)

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>$titleEnc</title>
  <style>
    body { font-family: 'Segoe UI', Arial, sans-serif; background:#f3f3f3; margin:0; padding:2rem; color:#222; }
    .card { max-width:640px; margin:0 auto; background:#fff; border:1px solid #ddd; border-radius:8px; padding:1.5rem 2rem; box-shadow:0 1px 3px rgba(0,0,0,.08); }
    h1 { font-size:1.3rem; margin-top:0; }
    label { display:block; margin:1rem 0 .3rem; font-weight:600; }
    input[type=text], input[type=password], select { width:100%; padding:.5rem; border:1px solid #bbb; border-radius:4px; box-sizing:border-box; font-size:1rem; }
    button { margin-top:1.5rem; padding:.6rem 1.2rem; background:#0067b8; color:#fff; border:0; border-radius:4px; font-size:1rem; cursor:pointer; }
    button:hover { background:#005a9e; }
    .meta { color:#666; font-size:.85rem; }
    .topbar { display:flex; justify-content:space-between; align-items:center; gap:1rem; margin-bottom:.5rem; }
    .logout { margin:0; }
    .logout button { margin:0; padding:.35rem .8rem; font-size:.8rem; background:#666; }
    .logout button:hover { background:#4d4d4d; }
    .err { background:#fde7e9; border:1px solid #d13438; color:#a4262c; padding:.6rem .8rem; border-radius:4px; margin-bottom:1rem; }
    textarea { width:100%; height:9rem; font-family:Consolas,monospace; font-size:.8rem; }
    a { color:#0067b8; }
  </style>
</head>
<body>
  <div class="card">
$Body
  </div>
</body>
</html>
"@
}

function Get-OdjLogoutForm
{
    <#
    .SYNOPSIS
        Builds the sign-out form posted to <BasePath>/logout. Only rendered in
        standalone session mode (WebUi.AuthMode = 'WindowsAd'); under IIS the
        Windows session is owned by the browser/IIS, so no in-app logout applies.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $BasePath,

        [Parameter()]
        [switch]
        $ShowLogout
    )

    if (-not $ShowLogout)
    {
        return ''
    }

    $action = [System.Net.WebUtility]::HtmlEncode($BasePath.TrimEnd('/') + '/logout')
    return "<form method=`"post`" action=`"$action`" class=`"logout`"><button type=`"submit`">Sign out</button></form>"
}

function Get-OdjLoginBody
{
    <#
    .SYNOPSIS
        Builds the Active Directory credential login form used when the service
        is hosted standalone (WebUi.AuthMode = 'WindowsAd').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $BasePath,

        [Parameter()]
        [string]
        $ErrorMessage
    )

    $errHtml = ''
    if (-not [string]::IsNullOrEmpty($ErrorMessage))
    {
        $errHtml = '<div class="err">' + [System.Net.WebUtility]::HtmlEncode($ErrorMessage) + '</div>'
    }

    $action = [System.Net.WebUtility]::HtmlEncode($BasePath.TrimEnd('/') + '/login')

    return @"
<h1>Sign in</h1>
$errHtml
<p class="meta">Use your Active Directory credentials. Access is restricted to authorized administrators.</p>
<form method="post" action="$action" autocomplete="off">
  <label for="username">User name</label>
  <input type="text" id="username" name="username" autocomplete="username" required />
  <label for="password">Password</label>
  <input type="password" id="password" name="password" autocomplete="current-password" required />
  <button type="submit">Sign in</button>
</form>
"@
}

function Get-OdjFormBody
{
    <#
    .SYNOPSIS
        Builds the provisioning form, pre-populating the allowed targets.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]
        $Targets,

        [Parameter(Mandatory)]
        [string]
        $CsrfToken,

        [Parameter(Mandatory)]
        [string]
        $User,

        [Parameter(Mandatory)]
        [string]
        $BasePath,

        [Parameter()]
        [string]
        $ErrorMessage,

        [Parameter()]
        [switch]
        $ShowLogout
    )

    $options = ''
    for ($i = 0; $i -lt $Targets.Count; $i++)
    {
        $t = $Targets[$i]
        $label = '{0} / {1} (names start with {2})' -f $t.Domain, $t.MachineOU, $t.NamePrefix
        $options += ('<option value="{0}">{1}</option>' -f $i, [System.Net.WebUtility]::HtmlEncode($label))
    }

    $errBlock = ''
    if ($ErrorMessage)
    {
        $errBlock = '<div class="err">' + [System.Net.WebUtility]::HtmlEncode($ErrorMessage) + '</div>'
    }

    $userEnc = [System.Net.WebUtility]::HtmlEncode($User)
    $tokenEnc = [System.Net.WebUtility]::HtmlEncode($CsrfToken)
    $logoutHtml = Get-OdjLogoutForm -BasePath $BasePath -ShowLogout:$ShowLogout

    return @"
<h1>Offline Domain Join</h1>
<div class="topbar"><span class="meta">Signed in as <strong>$userEnc</strong></span>$logoutHtml</div>
$errBlock
<form method="post" action="$BasePath/provision">
  <input type="hidden" name="csrf" value="$tokenEnc" />
  <label for="targetIndex">Target domain / OU</label>
  <select id="targetIndex" name="targetIndex" required>
$options
  </select>
  <label for="machineName">Computer name</label>
  <input type="text" id="machineName" name="machineName" maxlength="15" required placeholder="e.g. RESA-WEB01" />
  <label for="outputFormat">Output</label>
  <select id="outputFormat" name="outputFormat">
    <option value="blob">Base64 blob</option>
    <option value="unattend">Unattend XML fragment</option>
  </select>
  <button type="submit">Generate</button>
</form>
"@
}

function Get-OdjResultBody
{
    <#
    .SYNOPSIS
        Builds the result page showing the generated provisioning data.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $MachineName,

        [Parameter(Mandatory)]
        [string]
        $Domain,

        [Parameter(Mandatory)]
        [string]
        $Payload,

        [Parameter(Mandatory)]
        [string]
        $BasePath,

        [Parameter()]
        [string]
        $Format = 'blob',

        [Parameter()]
        [switch]
        $ShowLogout
    )

    $nameEnc = [System.Net.WebUtility]::HtmlEncode($MachineName)
    $domainEnc = [System.Net.WebUtility]::HtmlEncode($Domain)
    $payloadEnc = [System.Net.WebUtility]::HtmlEncode($Payload)

    $isUnattend = $Format.ToLowerInvariant() -eq 'unattend'
    if ($isUnattend)
    {
        $fileName = $MachineName + '-unattend.xml'
        $mimeType = 'application/xml'
    }
    else
    {
        $fileName = $MachineName + '.txt'
        $mimeType = 'text/plain'
    }

    $fileNameJs = $fileName -replace '\\', '\\' -replace "'", "\'"
    $mimeJs = $mimeType -replace "'", "\'"
    $logoutHtml = Get-OdjLogoutForm -BasePath $BasePath -ShowLogout:$ShowLogout

    return @"
<h1>Result</h1>
<div class="topbar"><span class="meta">Computer <strong>$nameEnc</strong> in <strong>$domainEnc</strong></span>$logoutHtml</div>
<label>Provisioning data</label>
<textarea id="odjPayload" readonly onclick="this.select()">$payloadEnc</textarea>
<button type="button" id="odjDownload">Download</button>
<p><a href="$BasePath">&larr; Create another</a></p>
<script>
(function () {
  var btn = document.getElementById('odjDownload');
  var area = document.getElementById('odjPayload');
  if (!btn || !area) { return; }
  btn.addEventListener('click', function () {
    var blob = new Blob([area.value], { type: '$mimeJs' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = '$fileNameJs';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  });
})();
</script>
"@
}
