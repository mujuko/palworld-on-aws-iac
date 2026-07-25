[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
    [ValidateNotNullOrEmpty()]
    [string[]]$IpAddresses,

    [switch]$Tofu
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RdapCidr {
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )

    $parsedAddress = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($Address.Trim(), [ref]$parsedAddress) -or
        $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Address must be a valid public IPv4 address: $Address"
    }

    $normalizedAddress = $parsedAddress.ToString()
    if ($parsedAddress.GetAddressBytes()[0] -in @(0, 10, 127) -or
        ($normalizedAddress -match '^169\.254\.') -or
        ($normalizedAddress -match '^172\.(1[6-9]|2[0-9]|3[01])\.') -or
        ($normalizedAddress -match '^192\.168\.')) {
        throw "Address must be a public IPv4 address: $normalizedAddress"
    }

    $requestUri = "https://rdap.org/ip/$normalizedAddress"
    try {
        $response = Invoke-RestMethod -Uri $requestUri -MaximumRedirection 5 -TimeoutSec 30
    }
    catch {
        throw "RDAP lookup failed for $normalizedAddress`: $($_.Exception.Message)"
    }

    $cidrEntries = @($response.cidr0_cidrs | Where-Object { $_.v4prefix -and $null -ne $_.length })
    if ($cidrEntries.Count -eq 0) {
        throw "The RDAP response did not contain cidr0_cidrs. Registered range: $($response.startAddress) - $($response.endAddress)"
    }

    $sourceUrl = [string]($response.links | Where-Object { $_.rel -eq 'self' } | Select-Object -ExpandProperty href -First 1)
    foreach ($entry in $cidrEntries) {
        $prefixLength = [int]$entry.length
        [pscustomobject]@{
            IpAddress    = $normalizedAddress
            NetworkName  = $response.name
            StartAddress = $response.startAddress
            EndAddress   = $response.endAddress
            Cidr         = "$($entry.v4prefix)/$prefixLength"
            AddressCount = [uint64][math]::Pow(2, 32 - $prefixLength)
            Source       = $sourceUrl
        }
    }
}

$results = @($IpAddresses | ForEach-Object { Resolve-RdapCidr -Address $_ })

if ($Tofu) {
    'allowed_cidrs = ['
    foreach ($cidr in @($results.Cidr | Sort-Object -Unique)) {
        '  "{0}",' -f $cidr
    }
    ']'
    return
}

$results

Write-Warning 'The CIDR values are registered allocation ranges, not a guarantee that the member will receive the same range after their public IP changes.'
