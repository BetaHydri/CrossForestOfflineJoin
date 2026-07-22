#Requires -Version 5.1

BeforeAll {
    $uiScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\src\WebService\OfflineJoinWebUi.ps1'
    . (Resolve-Path -LiteralPath $uiScript).Path

    $script:Targets = @(
        [pscustomobject]@{ Domain = 'res-a.example.com'; MachineOU = 'OU=Server,DC=res-a,DC=example,DC=com'; NamePrefix = 'RESA' }
        [pscustomobject]@{ Domain = 'res-b.example.com'; MachineOU = 'OU=Server,DC=res-b,DC=example,DC=com'; NamePrefix = 'RESB' }
    )
}

Describe 'Get-OdjHtmlPage' {

    It 'Wraps the body in a full HTML document' {
        $html = Get-OdjHtmlPage -Title 'Test' -Body '<p>hello</p>'
        $html | Should -BeLike '*<!DOCTYPE html>*'
        $html | Should -BeLike '*<p>hello</p>*'
        $html | Should -BeLike '*</html>*'
    }

    It 'HTML-encodes the title to prevent XSS' {
        $html = Get-OdjHtmlPage -Title '<script>alert(1)</script>' -Body 'x'
        $html | Should -BeLike '*&lt;script&gt;alert(1)&lt;/script&gt;*'
        $html | Should -Not -BeLike '*<title><script>*'
    }
}

Describe 'Get-OdjFormBody' {

    It 'Renders one option per allowed target with its index as value' {
        $body = Get-OdjFormBody -Targets $script:Targets -CsrfToken 'abc' -User 'CONTOSO\admin' -BasePath '/ui'
        $body | Should -BeLike '*<option value="0">*'
        $body | Should -BeLike '*<option value="1">*'
        $body | Should -BeLike '*res-a.example.com*'
        $body | Should -BeLike '*RESB*'
    }

    It 'Embeds the CSRF token in a hidden field' {
        $body = Get-OdjFormBody -Targets $script:Targets -CsrfToken 'tok123' -User 'u' -BasePath '/ui'
        $body | Should -BeLike '*name="csrf" value="tok123"*'
    }

    It 'Posts to the configured base path' {
        $body = Get-OdjFormBody -Targets $script:Targets -CsrfToken 'x' -User 'u' -BasePath '/admin/join'
        $body | Should -BeLike '*action="/admin/join/provision"*'
    }

    It 'Shows an error banner only when a message is supplied' {
        $withError = Get-OdjFormBody -Targets $script:Targets -CsrfToken 'x' -User 'u' -BasePath '/ui' -ErrorMessage 'Nope'
        $withError | Should -BeLike '*class="err"*Nope*'

        $withoutError = Get-OdjFormBody -Targets $script:Targets -CsrfToken 'x' -User 'u' -BasePath '/ui'
        $withoutError | Should -Not -BeLike '*class="err"*'
    }

    It 'HTML-encodes the signed-in user to prevent XSS' {
        $body = Get-OdjFormBody -Targets $script:Targets -CsrfToken 'x' -User '<img src=x onerror=alert(1)>' -BasePath '/ui'
        $body | Should -BeLike '*&lt;img src=x onerror=alert(1)&gt;*'
        $body | Should -Not -BeLike '*<img src=x onerror=alert(1)>*'
    }

    It 'Handles an empty target list without emitting target options' {
        $body = Get-OdjFormBody -Targets @() -CsrfToken 'x' -User 'u' -BasePath '/ui'
        $body | Should -Not -BeLike '*<option value="0"*'
        $body | Should -BeLike '*<select id="targetIndex"*'
    }
}

Describe 'Get-OdjResultBody' {

    It 'Shows the machine, domain and payload' {
        $body = Get-OdjResultBody -MachineName 'RESA-WEB01' -Domain 'res-a.example.com' -Payload 'BLOBDATA' -BasePath '/ui'
        $body | Should -BeLike '*RESA-WEB01*'
        $body | Should -BeLike '*res-a.example.com*'
        $body | Should -BeLike '*BLOBDATA*'
        $body | Should -BeLike '*href="/ui"*'
    }

    It 'HTML-encodes the payload to prevent XSS' {
        $body = Get-OdjResultBody -MachineName 'PC1' -Domain 'd' -Payload '</textarea><script>bad()</script>' -BasePath '/ui'
        $body | Should -BeLike '*&lt;/textarea&gt;&lt;script&gt;bad()&lt;/script&gt;*'
        $body | Should -Not -BeLike '*</textarea><script>bad()*'
    }
}
