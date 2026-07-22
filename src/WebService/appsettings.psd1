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

    # Audit log (no blob content is logged).
    AuditLogPath  = 'C:\ProgramData\OfflineJoinService\audit.log'
}
