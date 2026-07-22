@{
    # HTTPS endpoint of the service.
    Endpoint      = @{
        Address           = '*'
        Port              = 8443
        # Thumbprint of a server certificate installed in LocalMachine\My.
        CertificateThumbprint = 'REPLACE-WITH-CERT-THUMBPRINT'
    }

    # Allowed requesters (VMware automation). API keys are stored as a
    # SHA256 hash, NOT in clear text. Generate the hash with:
    #   [BitConverter]::ToString(
    #     [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    #       [Text.Encoding]::UTF8.GetBytes('MY-API-KEY'))).Replace('-','').ToLower()
    ApiClients    = @(
        @{
            Name         = 'vmware-aria-automation'
            ApiKeySha256 = 'REPLACE-WITH-SHA256-OF-API-KEY'
        }
    )

    # Allow-list of permitted targets. Only the Forest/Domain/OU combinations
    # listed here may be provisioned.
    AllowedTargets = @(
        @{
            Domain      = 'res-a.example.com'
            MachineOU   = 'OU=Server,DC=res-a,DC=example,DC=com'
            NamePrefix  = 'RESA'
        }
        @{
            Domain      = 'res-b.example.com'
            MachineOU   = 'OU=Server,DC=res-b,DC=example,DC=com'
            NamePrefix  = 'RESB'
        }
    )

    # Optional browser form for AD admins. Requires IIS Windows Authentication
    # hosting (see the quick-start section "Web UI for AD admins"). Only members
    # of AdminGroup may open the form; the server re-validates every request
    # against AllowedTargets above. Disabled by default.
    WebUi         = @{
        Enabled    = $false
        AdminGroup = 'GG-ODJ-WebAdmins'
        BasePath   = '/ui'
    }

    # Audit log (no blob content is logged).
    AuditLogPath  = 'C:\ProgramData\OfflineJoinService\audit.log'

    # Optional logging settings (BSI IT-Grundschutz OPS.1.1.5). The file log above
    # is always written. Set EventLog.Enabled = $true to additionally mirror every
    # security-relevant event to the Windows Event Log, which eases central
    # collection (e.g. via Windows Event Forwarding to a SIEM). The event source
    # should be registered once with elevated rights (install.ps1 -EnableEventLog,
    # or New-EventLog -LogName Application -Source 'OfflineJoinService'); the
    # service tries a best-effort runtime registration as a fallback. The source
    # name must be unique and must not equal an existing log name.
    Logging       = @{
        EventLog = @{
            Enabled = $false
            LogName = 'Application'
            Source  = 'OfflineJoinService'
        }
    }
}
