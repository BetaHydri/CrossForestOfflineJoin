@{
    # HTTPS endpoint of the service.
    Endpoint      = @{
        Address           = '*'
        Port              = 8443
        # Thumbprint of a server certificate installed in LocalMachine\My.
        CertificateThumbprint = 'REPLACE-WITH-CERT-THUMBPRINT'
        # Optional certificate store overrides. Pode defaults to CurrentUser\My,
        # which cannot see a LocalMachine certificate, so the service defaults
        # these to 'My' / 'LocalMachine'. Only set them to override that default.
        # CertificateStoreName     = 'My'
        # CertificateStoreLocation = 'LocalMachine'
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
    # NOTE: MachineOU must be an OU (or container) that ACTUALLY EXISTS in the
    # target domain, written with the correct object type prefix. The built-in
    # computers container is 'CN=Computers' (not 'OU=Computers'); a custom OU is
    # 'OU=<name>'. If the DN does not exist, djoin /provision fails with 0x2
    # ("The system cannot find the file specified.").
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

    # Optional browser form for AD admins. Only members of AdminGroup may open
    # the form; the server re-validates every request against AllowedTargets
    # above. Disabled by default.
    #
    # AuthMode selects how admins authenticate:
    #   'WindowsAd' (default) - standalone HTTPS. A hosted HTML login form
    #                collects AD credentials that are validated directly against
    #                Active Directory over the TLS channel and backed by a
    #                server-side session cookie. No IIS needed.
    #   'IIS'      - the service runs behind IIS with Windows Authentication and
    #                the ASP.NET Core Module forwards the Windows identity. Use
    #                this for seamless Kerberos single sign-on.
    WebUi         = @{
        Enabled    = $false
        AuthMode   = 'WindowsAd'
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
