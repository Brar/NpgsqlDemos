using NpgsqlTypes;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LoadBalancing;

public class IPAddressConverter : JsonConverter<IPAddress>
{
    public override IPAddress? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var value = reader.GetString();
        return value == null ? null : IPAddress.Parse(value);
    }

    public override void Write(Utf8JsonWriter writer, IPAddress value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToString());
}

public class LsnUInt64Converter : JsonConverter<NpgsqlLogSequenceNumber>
{
    public override NpgsqlLogSequenceNumber Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        return (NpgsqlLogSequenceNumber)reader.GetUInt64();
    }

    public override void Write(Utf8JsonWriter writer, NpgsqlLogSequenceNumber value, JsonSerializerOptions options)
        => writer.WriteNumberValue((ulong)value);
}

public class LsnStringConverter : JsonConverter<NpgsqlLogSequenceNumber>
{
    public override NpgsqlLogSequenceNumber Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var value = reader.GetString();
        return value == null ? NpgsqlLogSequenceNumber.Invalid : NpgsqlLogSequenceNumber.Parse(value);
    }

    public override void Write(Utf8JsonWriter writer, NpgsqlLogSequenceNumber value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToString());
}

