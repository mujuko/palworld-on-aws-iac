[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $ArchivePath,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TofuOutput {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $output = & tofu output -raw $Name 2>$null
    $exitCode = $LASTEXITCODE
    $value = ($output | Out-String).Trim()
    if ($exitCode -ne 0 -or -not $value) {
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

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw 'aws was not found. Install and configure the AWS CLI.'
}

if (-not (Get-Command tofu -ErrorAction SilentlyContinue)) {
    throw 'tofu was not found. Install OpenTofu.'
}

$archive = Get-Item -LiteralPath $ArchivePath -ErrorAction Stop
if ($archive.PSIsContainer -or $archive.Name -notmatch '\.tar\.gz$') {
    throw 'ArchivePath must point to a .tar.gz backup file.'
}

if (-not $Force) {
    $confirmation = Read-Host '現在のセーブデータを置き換えます。続行するにはRESTOREと入力してください'
    if ($confirmation -cne 'RESTORE') {
        throw 'Restore cancelled.'
    }
}

$bucket = Get-TofuOutput -Name 'backup_bucket'
$instanceId = Get-TofuOutput -Name 'instance_id'
$objectKey = "backups/imports/palworld-import-$([guid]::NewGuid()).tar.gz"
$sourceUri = "s3://$bucket/$objectKey"

$null = Invoke-AwsCli -CommandArguments @(
    's3', 'cp',
    $archive.FullName, $sourceUri,
    '--sse', 'AES256',
    '--only-show-errors'
)
Write-Output "Uploaded the backup archive to $sourceUri"

$remoteCommand = "/usr/local/sbin/restore-palworld $sourceUri"
$commandId = (Invoke-AwsCli -CommandArguments @(
    'ssm', 'send-command',
    '--instance-ids', $instanceId,
    '--document-name', 'AWS-RunShellScript',
    '--comment', 'Restore Palworld save data',
    '--parameters', "commands=[`"$remoteCommand`"]",
    '--query', 'Command.CommandId',
    '--output', 'text'
) | Out-String).Trim()

$null = & aws ssm wait command-executed `
    --command-id $commandId `
    --instance-id $instanceId `
    --no-cli-pager
$waitExitCode = $LASTEXITCODE

$invocationJson = (Invoke-AwsCli -CommandArguments @(
    'ssm', 'get-command-invocation',
    '--command-id', $commandId,
    '--instance-id', $instanceId,
    '--query', '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}',
    '--output', 'json'
) | Out-String).Trim()
$invocation = $invocationJson | ConvertFrom-Json

if ($invocation.Output) {
    Write-Output $invocation.Output.TrimEnd()
}

if ($waitExitCode -ne 0 -or $invocation.Status -ne 'Success') {
    $errorMessage = if ($invocation.Error) { $invocation.Error.Trim() } else { 'No error output was returned.' }
    throw "The restore command failed with status $($invocation.Status). $errorMessage"
}

Write-Output 'Palworld save data restore completed.'
