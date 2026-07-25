[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretArn,

    [switch] $SkipRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TofuOutput {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [switch] $AllowMissing
    )

    $output = & tofu output -raw $Name 2>$null
    $exitCode = $LASTEXITCODE
    $value = ($output | Out-String).Trim()
    if ($exitCode -ne 0 -or -not $value) {
        if ($AllowMissing) {
            return $null
        }
        throw "Could not read $Name from the current OpenTofu state."
    }

    return $value
}

function Invoke-AwsCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $CommandArguments
    )

    $output = & aws @CommandArguments --no-cli-pager
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI command failed: aws $($CommandArguments[0]) $($CommandArguments[1])"
    }

    return $output
}

function Assert-PalworldPassword {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [int] $MinimumLength
    )

    if ($Value.Length -lt $MinimumLength -or $Value.Length -gt 64) {
        throw "$Name must be $MinimumLength-64 characters."
    }

    $forbiddenCharacters = @([char] 0x22, [char] 0x5c, [char] 0x0a, [char] 0x0d)
    if ($Value.IndexOfAny($forbiddenCharacters) -ge 0) {
        throw "$Name may not contain quotes, backslashes, or newlines."
    }
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw 'aws was not found. Install and configure the AWS CLI.'
}

if (-not (Get-Command tofu -ErrorAction SilentlyContinue)) {
    throw 'tofu was not found. Install OpenTofu.'
}

if (-not $SecretArn) {
    $SecretArn = Get-TofuOutput -Name 'credentials_secret_arn'
}

$serverPasswordSecure = $null
$adminPasswordSecure = $null
$serverPassword = $null
$adminPassword = $null
$secretFile = $null

try {
    $serverPasswordSecure = Read-Host '参加用パスワード' -AsSecureString
    $adminPasswordSecure = Read-Host '管理用パスワード' -AsSecureString
    $serverPassword = [System.Net.NetworkCredential]::new('', $serverPasswordSecure).Password
    $adminPassword = [System.Net.NetworkCredential]::new('', $adminPasswordSecure).Password

    Assert-PalworldPassword -Name 'ServerPassword' -Value $serverPassword -MinimumLength 12
    Assert-PalworldPassword -Name 'AdminPassword' -Value $adminPassword -MinimumLength 16
    if ($serverPassword -ceq $adminPassword) {
        throw 'AdminPassword must differ from ServerPassword.'
    }

    $secretJson = ConvertTo-Json -Compress -InputObject @{
        ServerPassword = $serverPassword
        AdminPassword  = $adminPassword
    }
    $secretFile = Join-Path ([System.IO.Path]::GetTempPath()) "palworld-credentials-$([guid]::NewGuid()).json"
    [System.IO.File]::WriteAllText($secretFile, $secretJson, [System.Text.UTF8Encoding]::new($false))
    $secretFileUri = 'file://' + ($secretFile -replace '\\', '/')

    $null = Invoke-AwsCli -CommandArguments @(
        'secretsmanager', 'put-secret-value',
        '--secret-id', $SecretArn,
        '--secret-string', $secretFileUri,
        '--query', 'VersionId',
        '--output', 'text'
    )
}
finally {
    if ($secretFile -and (Test-Path -LiteralPath $secretFile)) {
        Remove-Item -LiteralPath $secretFile -Force
    }
    if ($serverPasswordSecure) {
        $serverPasswordSecure.Dispose()
    }
    if ($adminPasswordSecure) {
        $adminPasswordSecure.Dispose()
    }
    $serverPassword = $null
    $adminPassword = $null
}

Write-Output 'Updated the Palworld credentials in Secrets Manager.'

if ($SkipRestart) {
    Write-Output 'Skipped the Palworld service restart.'
    return
}

$instanceId = Get-TofuOutput -Name 'instance_id' -AllowMissing
if (-not $instanceId) {
    Write-Output 'No running Palworld EC2 instance was found. The credentials will be applied when the server starts.'
    return
}

$commandId = (Invoke-AwsCli -CommandArguments @(
    'ssm', 'send-command',
    '--instance-ids', $instanceId,
    '--document-name', 'AWS-RunShellScript',
    '--comment', 'Apply updated Palworld credentials',
    '--parameters', 'commands=["systemctl restart palworld","systemctl is-active --quiet palworld"]',
    '--query', 'Command.CommandId',
    '--output', 'text'
) | Out-String).Trim()

$null = & aws ssm wait command-executed `
    --command-id $commandId `
    --instance-id $instanceId `
    --no-cli-pager
if ($LASTEXITCODE -ne 0) {
    $details = (& aws ssm get-command-invocation `
        --command-id $commandId `
        --instance-id $instanceId `
        --query '{Status:Status,Error:StandardErrorContent}' `
        --output json `
        --no-cli-pager | Out-String).Trim()
    throw "The secret was updated, but the Palworld service restart failed. SSM result: $details"
}

Write-Output 'Restarted the Palworld service through Systems Manager.'
