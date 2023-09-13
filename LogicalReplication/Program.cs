using System.CommandLine;
using Npgsql;
using Npgsql.Replication;
using Npgsql.Replication.PgOutput;
using Npgsql.Replication.PgOutput.Messages;
using NpgsqlTypes;

const string defaultDatabaseName = "LogicalReplication";
const string defaultSlotName = "hl7_slot";
const string defaultPublicationName = "hl7_message_pub";

var returnCode = 0;
var rootCommand = new RootCommand("Logical replication demo");

var hostOption = new Option<string>(new[]{"-h", "--host"}, () => "::1", "database server host or socket directory");
var portOption = new Option<ushort>(new[]{"-p", "--port"}, () => 5432, "database server port");
var usernameOption = new Option<string>(new[]{"-U", "--username"}, () => Environment.UserName, "database user name");
var databaseOption = new Option<string>(new[]{"-d", "--dbname"}, () => defaultDatabaseName, "database name to connect to");
var slotOption = new Option<string>(new[]{"-S", "--slot"}, () => defaultSlotName, "replication slot to use");
var publicationOption = new Option<string>(new[]{"-P", "--publication"}, () => defaultPublicationName, "publication to use");
var temporarySlotOption = new Option<bool>(new[]{"-T", "--temporary-slot"}, () => false, "use a temporary replication slot");

rootCommand.Add(hostOption);
rootCommand.Add(portOption);
rootCommand.Add(usernameOption);
rootCommand.Add(databaseOption);
rootCommand.Add(slotOption);
rootCommand.Add(publicationOption);
rootCommand.Add(temporarySlotOption);

rootCommand.SetHandler(async context => returnCode = await DoRootCommand(
    new()
    {
        Host = context.ParseResult.GetValueForOption(hostOption),
        Port = context.ParseResult.GetValueForOption(portOption),
        Username = context.ParseResult.GetValueForOption(usernameOption),
        Database = context.ParseResult.GetValueForOption(databaseOption)
    },
    context.ParseResult.GetValueForOption(slotOption)!,
    context.ParseResult.GetValueForOption(publicationOption)!,
    context.ParseResult.GetValueForOption(temporarySlotOption),
    context.GetCancellationToken()));
await rootCommand.InvokeAsync(args);
return returnCode;

static async Task<int> DoRootCommand(NpgsqlConnectionStringBuilder connectionStringBuilder, string replicationSlotName, string publicationName, bool temporarySlot, CancellationToken cancellationToken)
{
    try
    {
        ArgumentException.ThrowIfNullOrEmpty(replicationSlotName);
        ArgumentException.ThrowIfNullOrEmpty(publicationName);
        await using var ds = NpgsqlDataSource.Create(connectionStringBuilder);

        await using var replConn = new LogicalReplicationConnection(connectionStringBuilder.ConnectionString);
        await replConn.Open(cancellationToken);

        PgOutputReplicationSlot hl7Slot;
        
        // Check if our replication slot already exists.
        // If it does not, create it and read pre-existing data.
        await using var cmd = ds.CreateCommand($"SELECT EXISTS(SELECT FROM pg_replication_slots WHERE slot_name = '{replicationSlotName}' AND plugin = 'pgoutput')");
        if (!(bool)(await cmd.ExecuteScalarAsync(cancellationToken))!)
        {
            hl7Slot = await replConn.CreatePgOutputReplicationSlot(replicationSlotName, temporarySlot, cancellationToken: cancellationToken);
            await using var batch = ds.CreateBatch();
            batch.BatchCommands.Add(new("BEGIN ISOLATION LEVEL REPEATABLE READ,READ ONLY"));
            batch.BatchCommands.Add(new($"SET TRANSACTION SNAPSHOT '{hl7Slot.SnapshotName}'"));
            batch.BatchCommands.Add(new("SELECT id, message FROM hl7_messages ORDER BY message_timestamp, id"));
            await using var reader = await batch.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                var id = reader.GetInt64(0);
                var hl7Message = reader.GetString(1);
                ProcessNewData(id, hl7Message, null);
            }
        }
        else
            hl7Slot = new(replicationSlotName);

        // Start replicating
        // ToDo: Get the actual WAL end for the data we have already processed from our processing log.
        var walEnd = default(NpgsqlLogSequenceNumber);
        Console.WriteLine("Starting replication");
        Console.WriteLine("Press CTRL+C to exit");
        await foreach (var message in replConn.StartReplication(hl7Slot, new(publicationName, 1, true), cancellationToken, walEnd))
        {
            switch (message)
            {
                case InsertMessage insertMessage:
                {
                    var fields = insertMessage.NewRow.GetAsyncEnumerator(cancellationToken);
                    if (!await fields.MoveNextAsync())
                        throw new("Unexpected number of fields in replicated row.");
                    var field = fields.Current;
                    if (field.Kind != TupleDataKind.BinaryValue || field.GetFieldType() != typeof(long))
                        throw new("Unexpected field value.");
                    var id = await field.Get<long>(cancellationToken);

                    if (!await fields.MoveNextAsync())
                        throw new("Unexpected number of fields in replicated row.");
                    field = fields.Current;
                    if (field.Kind != TupleDataKind.BinaryValue || field.GetFieldType() != typeof(string))
                        throw new("Unexpected field value.");
                    var hl7Message = await field.Get<string>(cancellationToken);
                    ProcessNewData(id, hl7Message, insertMessage.WalEnd);
                    break;
                }
                // Todo: Possibly handle other message types (UpdateMessage, DeleteMessage, TruncateMessage, ...)
            }
            replConn.SetReplicationStatus(message.WalEnd);
        }
        return 0;

        void ProcessNewData(long id, string hl7Message, NpgsqlLogSequenceNumber? walEnd)
        {
            // Todo: Actually process the new data (e. g. parse the HL7 message, populate other tables and update the WAL end for processed data)
            Console.WriteLine(!walEnd.HasValue
                ? $"Processing existing data with id {id} and HL7 message '{hl7Message}'."
                : $"Processing inserted data with id {id} and HL7 message '{hl7Message}' (WAL end: {walEnd}).");
        }
    }
    catch (OperationCanceledException)
    {
        Console.WriteLine("Replication stopped");
        return 1;
    }
}



