[CmdletBinding()]
param()
#Requires -Version 7.3

$StartPort = 5432
$DatabaseName = 'LogicalReplication'
$PublicationName = 'hl7_message_pub'
$PrimaryName = 'primary'
$Verbose = $VerbosePreference -ne 'SilentlyContinue'


# Try to detect initdb in the path and if that fails try a few knows PostgreSQL bin directories
Get-Command -Name 'initdb' -CommandType Application -TotalCount 1 -Syntax -ErrorAction Ignore -OutVariable initdb > $null
if ($initdb) {
    $pgPath = [System.IO.Path]::GetDirectoryName($initdb)
}
else {
    foreach ($testPath in @('C:\Program Files\PostgreSQL\*\bin')) {
        $pgPath = Get-ChildItem -Path $testPath | sort -Property @{Expression={[System.Version]::new("$($_.Parent.Name).0")}; Descending = $true} | select -First 1 -ExpandProperty FullName
        if ($pgPath) {
            Get-Command -Name ([System.IO.Path]::Join($pgPath, 'initdb')) -TotalCount 1 -Syntax -ErrorAction Ignore -OutVariable initdb > $null
            if ($initdb) {
                break
            }
        }
    }
}

# detect the other PostgreSQL management commands
Get-Command -Name ([System.IO.Path]::Join($pgPath, 'pg_ctl')) -TotalCount 1 -Syntax -ErrorAction Stop -OutVariable pg_ctl > $null
Get-Command -Name ([System.IO.Path]::Join($pgPath, 'psql')) -TotalCount 1 -Syntax -ErrorAction Stop -OutVariable psql > $null

$clusterName = $PrimaryName
$port = $StartPort
$clusterPath = [System.IO.Path]::Join($PSScriptRoot, $clusterName)
$configPath = [System.IO.Path]::Join($clusterPath, 'postgresql.auto.conf')
$logFilePath = [System.IO.Path]::Join($PSScriptRoot, "$clusterName.log")

# Check if cluster exists
if (-not [System.IO.File]::Exists($configPath)) {
    Remove-Item -LiteralPath $clusterPath -Force -Recurse -ErrorAction Ignore

    Write-Host "Initialising database cluster '$clusterName'..." -NoNewline
    if ($Verbose) { $lastOutput = '' }
    $lastError = & $initdb -D $clusterPath -A trust --no-instructions 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_
        }
        elseif ($Verbose) {
            $lastOutput += (([System.Environment]::NewLine) + $_)
        }
    } | Join-String -Separator ([System.Environment]::NewLine)
    if ($Verbose) { Write-Host; Write-Verbose $lastOutput }
    if (-not $?) { Write-Host; Write-Error -Message $lastError -Category FromStdErr -ErrorAction Stop }
    Write-Host "done" -ForegroundColor Green

    Write-Host "Configuring database cluster '$clusterName'..." -NoNewline
    "port = $port
    unix_socket_directories = ''
    wal_level = logical
    cluster_name = '$clusterName'
    update_process_title = on" >> $configPath
    Write-Host "done" -ForegroundColor Green

    Write-Host "Starting database cluster '$clusterName'..." -NoNewline
    & $pg_ctl -D $clusterPath -l $logFilePath -s start
    if (-not $?) { exit 1 }
    Write-Host "done" -ForegroundColor Green

    Write-Host "Initialising database '$DatabaseName'..." -NoNewline
    if ($Verbose) { $lastOutput = '' }
    $lastError = "CREATE DATABASE `"$DatabaseName`";
\c `"$DatabaseName`"
CREATE TABLE hl7_messages
(
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    message text COMPRESSION lz4 NOT NULL,
    message_timestamp timestamp with time zone NOT NULL
);
ALTER TABLE hl7_messages ALTER COLUMN message SET STORAGE MAIN;
CREATE PUBLICATION `"$PublicationName`" FOR TABLE hl7_messages (id, message);" |
    & $psql -h localhost -p $port -d postgres -a 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_
        }
        elseif ($Verbose) {
            $lastOutput += (([System.Environment]::NewLine) + $_)
        }
    } | Join-String -Separator ([System.Environment]::NewLine)
    if ($Verbose) { Write-Host; Write-Verbose $lastOutput }
    if (-not $?) { Write-Host; Write-Error -Message $lastError -Category FromStdErr -ErrorAction Stop }
    Write-Host "done" -ForegroundColor Green
}
else {
    $pidFilePath = [System.IO.Path]::Join($clusterPath, 'postmaster.pid')
    if (-not [System.IO.File]::Exists($pidFilePath)) {
        Write-Host "Starting database cluster '$clusterName'..." -NoNewline
        & $pg_ctl -D $clusterPath -l $logFilePath -s start
        if (-not $?) { exit 1 }
        Write-Host "done" -ForegroundColor Green
    }
}

Write-Host "Press CTRL+C to exit"
[System.Console]::TreatControlCAsInput = $true
while ($true)
{
    if ([console]::KeyAvailable)
    {
        $key = [system.console]::ReadKey($true)
        if (($key.Modifiers -band [System.ConsoleModifiers]"Control") -and ($key.Key -eq "C"))
        {
            [System.Console]::TreatControlCAsInput = $false
            break
        }
    }
    Start-Sleep -Milliseconds 100
}

$clusterName = $PrimaryName
$clusterPath = [System.IO.Path]::Join($PSScriptRoot, $clusterName)
Write-Host "Shutting down database cluster '$clusterName'..." -NoNewline
if ($Verbose) { $lastOutput = '' }
$lastError = & $pg_ctl -D $clusterPath stop 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) {
        $_
    }
    elseif ($Verbose) {
        $lastOutput += (([System.Environment]::NewLine) + $_)
    }
} | Join-String -Separator ([System.Environment]::NewLine)
if ($Verbose) { Write-Host; Write-Verbose $lastOutput }
if (-not $?) { Write-Host; Write-Error -Message $lastError -Category FromStdErr -ErrorAction Stop }
Write-Host "done" -ForegroundColor Green
