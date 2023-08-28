[CmdletBinding()]
param()
#Requires -Version 7.3

$StartPort = 5434
$PrimaryName = 'primary'
$ReplicaPrefix = 'replica_'
$SlotPrefix = 'slot_'
$ReplicaCount = 5

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
Get-Command -Name ([System.IO.Path]::Join($pgPath, 'pg_basebackup')) -TotalCount 1 -Syntax -ErrorAction Stop -OutVariable pg_basebackup > $null

$clusterName = $PrimaryName
$port = $StartPort
$clusterPath = [System.IO.Path]::Join($PSScriptRoot, $clusterName)
$configPath = [System.IO.Path]::Join($clusterPath, 'postgresql.auto.conf')
$logFilePath = [System.IO.Path]::Join($PSScriptRoot, "$clusterName.log")

# Check if cluster exists
if (-not [System.IO.File]::Exists($configPath)) {
    Remove-Item -LiteralPath $clusterPath -Force -Recurse -ErrorAction Ignore
    Remove-Item -Path ([System.IO.Path]::Join($PSScriptRoot, "$ReplicaPrefix[0-9]")) -Force -Recurse -ErrorAction Ignore
    Write-Verbose "Initialising and starting cluster database for '$clusterName'..."
    & $initdb -D $clusterPath -A trust --no-instructions > $null
    $replicaNames = 1..$ReplicaCount | % {"$ReplicaPrefix$_"}

    "port = $port
    unix_socket_directories = ''
    wal_level = logical
    synchronous_standby_names = 'FIRST 2 ($($replicaNames | Join-String -Separator ", "))'
    cluster_name = '$clusterName'
    update_process_title = on" >> $configPath
    & $pg_ctl -D $clusterPath -l $logFilePath -s start
    & $psql -h localhost -p $port -d postgres -c "DO 'BEGIN FOR i IN 1..$ReplicaCount LOOP EXECUTE ''SELECT pg_create_physical_replication_slot('' || quote_literal (''$SlotPrefix'' || i) || '')''; END LOOP; END';" > $null
    Write-Verbose "Database cluster started"
}
else {
    $pidFilePath = [System.IO.Path]::Join($clusterPath, 'postmaster.pid')
    if (-not [System.IO.File]::Exists($pidFilePath)) {
        Write-Verbose "Starting database cluster for '$clusterName'..."
        & $pg_ctl -D $clusterPath -l $logFilePath -s start
        Write-Verbose "Database cluster started"
    }
}

for ($i = 1; $i -le $ReplicaCount; $i++) {
    $port++
    $clusterName = $ReplicaPrefix + $i
    $slotName = $SlotPrefix + $i
    $clusterPath = [System.IO.Path]::Join($PSScriptRoot, $clusterName)
    $configPath = [System.IO.Path]::Join($clusterPath, 'postgresql.auto.conf')
    $logFilePath = [System.IO.Path]::Join($PSScriptRoot, "$clusterName.log")
    $standbySignalPath = [System.IO.Path]::Join($clusterPath, 'standby.signal')

    # Check if cluster exists
    if (-not [System.IO.File]::Exists($configPath)) {
        Write-Verbose "Initialising and starting database cluster for '$clusterName'..."
        & $pg_basebackup -D $clusterPath -p $StartPort -h localhost > $null

        "port = $port
        primary_conninfo = 'host=localhost port=$StartPort application_name=$clusterName'
        primary_slot_name = '$slotName'
        cluster_name = '$clusterName'
        update_process_title = on" >> $configPath

        "" > $standbySignalPath

        & $pg_ctl -D $clusterPath -l $logFilePath -s start
        Write-Verbose "Database cluster started"
    }
    else {
        $pidFilePath = [System.IO.Path]::Join($clusterPath, 'postmaster.pid')
        if (-not [System.IO.File]::Exists($pidFilePath)) {
            Write-Verbose "Starting database cluster for '$clusterName'..."
            & $pg_ctl -D $clusterPath -l $logFilePath -s start
            Write-Verbose "Database cluster started"
        }
    }
}

[System.Console]::TreatControlCAsInput = $true
Write-Verbose "Starting web server..."
& dotnet build --verbosity quiet --nologo > $null
$webserverJob = & dotnet run --no-build --project $PSScriptRoot --verbosity quiet &
while ($true)
{
    Receive-Job -Job $webserverJob
    if ([console]::KeyAvailable)
    {
        $key = [system.console]::ReadKey($true)
        if (($key.Modifiers -band [System.ConsoleModifiers]"Control") -and ($key.Key -eq "C"))
        {
            # We'd rather terminate the web server gracefully but that's too complicated
            Write-Verbose "Killing web server..."
            Remove-Job -Job $webserverJob -Force
            Write-Verbose "Web server killed"
            [System.Console]::TreatControlCAsInput = $false
            break
        }
    }
    Start-Sleep -Milliseconds 100
}


for ($i = $ReplicaCount; $i -ge 1; $i--) {
    $clusterName = $ReplicaPrefix + $i
    $clusterPath = [System.IO.Path]::Join($PSScriptRoot, $clusterName)
    Write-Verbose "Shutting down database cluster for '$clusterName'..."
    & $pg_ctl -D $clusterPath stop > $null
    Write-Verbose "Database cluster shut down"
}

$clusterName = $PrimaryName
$clusterPath = [System.IO.Path]::Join($PSScriptRoot, $clusterName)
Write-Verbose "Shutting down database cluster for '$clusterName'..."
& $pg_ctl -D $clusterPath stop > $null
Write-Verbose "Database cluster shut down"
