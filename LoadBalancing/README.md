# Load balancing demo for Npgsql

## Initial PostgreSQL setup

> **_NOTE:_**  Make sure the PostgreSQL binary directory is in your path.

### Set up the primary cluster

Initialize the cluster
```
initdb -D ./primary
```

Change the following settings in ./primary/postgresql.conf
```
port = 5434
unix_socket_directories = ''
wal_level = logical
synchronous_standby_names = 'FIRST 2 (replica_1, replica_2, replica_3, replica_4, replica_5)'
cluster_name = 'primary'
update_process_title = on
```

Start the primary cluster
```
pg_ctl -D ./primary -l ./primary.log start
```

Create physical replication slots for the replicas
```
psql -h localhost -p 5434 -d postgres -c "DO 'BEGIN FOR i IN 1..5 LOOP EXECUTE ''SELECT pg_create_physical_replication_slot('' || quote_literal (''slot_'' || i) || '')''; END LOOP; END';"
```

### Set up the the replicas

> Perform the following steps for each of the 5 replicas. Change the replica number, the slot number and the replica port accordingly.

Initialize the replica by taking a base backup
```
pg_basebackup -D ./replica_1 -p 5434 -h localhost
```

Change the following settings in ./replica_1/postgresql.conf
```
port = 5435
primary_conninfo = 'host=localhost port=5434 application_name=replica_1'
primary_slot_name = 'slot_1'
cluster_name = 'replica_1'
update_process_title = on
```

Create a standby.signal file in the `./replica_1` directory

Start the replica
```
pg_ctl -D ./replica_1 -l ./replica_1.log start
```

## Running and monitoring the application

Run the application.
Next to other things it will output it's process id and URL to the console.
```
dotnet run
```

Monitor the application (see https://www.npgsql.org/doc/diagnostics.html)
```
dotnet counters monitor Npgsql -p <PID>
```

Open the application's website in a browser and start playing with it.