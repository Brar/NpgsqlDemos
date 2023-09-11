using System.CommandLine;
using Microsoft.Extensions.Configuration;
using Npgsql;
using Npgsql.Replication;
using Npgsql.Replication.PgOutput;
using Npgsql.Replication.PgOutput.Messages;

const string connectionStringName = "PrimaryConnection";
const string replicationSlotName = "hl7_slot";
const string publicationName = "hl7_message_pub";

var returnCode = 0;
var rootCommand = new RootCommand("Logical replication demo");
rootCommand.SetHandler(async context => returnCode = await DoRootCommand(context.GetCancellationToken()));
await rootCommand.InvokeAsync(args);
return returnCode;

static async Task<int> DoRootCommand(CancellationToken cancellationToken)
{
    try
    {
        var configuration =  new ConfigurationBuilder().AddJsonFile("appsettings.json");
        var config = configuration.Build();
        var connectionString = config.GetConnectionString(connectionStringName) ?? throw new InvalidOperationException("We need a connection string.");
        await using var ds = NpgsqlDataSource.Create(connectionString);

        await using var replConn = new LogicalReplicationConnection(connectionString);
        await replConn.Open(cancellationToken);

        PgOutputReplicationSlot hl7Slot;
        
        // Check if our replication slot already exists.
        // If it does not, create it and read pre-existing data.
        await using var cmd = ds.CreateCommand($"SELECT EXISTS(SELECT FROM pg_replication_slots WHERE slot_name = '{replicationSlotName}' AND plugin = 'pgoutput')");
        if (!(bool)(await cmd.ExecuteScalarAsync(cancellationToken))!)
        {
            hl7Slot = await replConn.CreatePgOutputReplicationSlot(replicationSlotName, cancellationToken: cancellationToken);
            await using var batch = ds.CreateBatch();
            batch.BatchCommands.Add(new("BEGIN ISOLATION LEVEL REPEATABLE READ,READ ONLY"));
            batch.BatchCommands.Add(new($"SET TRANSACTION SNAPSHOT '{hl7Slot.SnapshotName}'"));
            batch.BatchCommands.Add(new("SELECT id, message FROM hl7_messages"));
            await using var reader = await batch.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                var id = reader.GetInt64(0);
                var hl7Message = reader.GetString(1);
                ProcessNewData(id, hl7Message, true);
            }
        }
        else
            hl7Slot = new(replicationSlotName);

        // Start replicating
        await foreach (var message in replConn.StartReplication(hl7Slot, new(publicationName, 1, true), cancellationToken))
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
                    ProcessNewData(id, hl7Message, false);
                    break;
                }
                // Todo: Possibly handle other message types (UpdateMessage, DeleteMessage, TruncateMessage, ...)
            }
            replConn.SetReplicationStatus(message.WalEnd);
        }
        return 0;

        void ProcessNewData(long id, string hl7Message, bool preexisting)
        {
            // Todo: Actually process the new data (e. g. parse the HL7 message and populate other tables)
            Console.WriteLine(preexisting
                ? $"Processing existing data with id: {id} and HL7 message '{hl7Message}'."
                : $"Processing inserted data with id: {id} and HL7 message '{hl7Message}'.");
        }
    }
    catch (OperationCanceledException)
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.Error.WriteLine("The application was cancelled");
        Console.ResetColor();
        return 1;
    }
}



