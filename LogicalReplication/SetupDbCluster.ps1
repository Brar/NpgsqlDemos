[CmdletBinding()]
param()
#Requires -Version 7.3

$StartPort = 5434
$PrimaryName = 'primary'

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
    Write-Verbose "Initialising and starting cluster database for '$clusterName'..."
    & $initdb -D $clusterPath -A trust --no-instructions > $null

    "port = $port
    unix_socket_directories = ''
    wal_level = logical
    cluster_name = '$clusterName'
    update_process_title = on" >> $configPath
    & $pg_ctl -D $clusterPath -l $logFilePath -s start
    Write-Verbose "Database cluster started"

    "CREATE DATABASE `"LogicalReplication`";
    \c `"LogicalReplication`"
    CREATE TABLE hl7_messages
    (
        id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
        message text NOT NULL,
        other_stuff text
    );
    CREATE PUBLICATION hl7_message_pub FOR TABLE hl7_messages (id, message);
    " | & $psql -h localhost -p $port -d postgres > $null
}
else {
    $pidFilePath = [System.IO.Path]::Join($clusterPath, 'postmaster.pid')
    if (-not [System.IO.File]::Exists($pidFilePath)) {
        Write-Verbose "Starting database cluster for '$clusterName'..."
        & $pg_ctl -D $clusterPath -l $logFilePath -s start
        Write-Verbose "Database cluster started"
    }
}

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
Write-Verbose "Shutting down database cluster for '$clusterName'..."
& $pg_ctl -D $clusterPath stop > $null
Write-Verbose "Database cluster shut down"
