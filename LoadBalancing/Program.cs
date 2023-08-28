using LoadBalancing;
using Microsoft.EntityFrameworkCore;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.AddConsole();
builder.Services.AddDbContext<ApplicationDbContext>(o => o.UseNpgsql(builder.Configuration.GetConnectionString("PrimaryConnection")).UseSnakeCaseNamingConvention());
builder.Services.AddDbContext<QueryDbContext>(o => o.UseNpgsql(builder.Configuration.GetConnectionString("ShortRunningQueryConnection")).UseSnakeCaseNamingConvention());
builder.Services.AddDbContext<LongRunningQueryDbContext>(o => o.UseNpgsql(builder.Configuration.GetConnectionString("LongRunningQueryConnection")).UseSnakeCaseNamingConvention());

var app = builder.Build();

// Prepare the database and seed it with some initial data
await using (var ctx = new ApplicationDbContext(new DbContextOptionsBuilder<ApplicationDbContext>().UseNpgsql(builder.Configuration.GetConnectionString("SetupConnection")).UseSnakeCaseNamingConvention().Options))
{
    await ctx.Database.EnsureDeletedAsync();
    await ctx.Database.EnsureCreatedAsync();
    await ctx.Pathogens.AddRangeAsync(new(){Name = "Acinetobacter baumannii"}, new(){Name = "Escherichia coli"}, new(){Name = "Klebsiella pneumoniae"}, new(){Name = "Staphylococcus aureus"});
    await ctx.SaveChangesAsync();
}

app.UseDefaultFiles();
app.UseStaticFiles();
NpgsqlLoggingConfiguration.InitializeLogging(app.Services.GetRequiredService<ILoggerFactory>(), parameterLoggingEnabled: true);

app.MapGet("/api/pathogens", async (LongRunningQueryDbContext db, string? name) => {
    var x = await (name == null
        ? db.Pathogens.ToListAsync()
        : db.Pathogens.Where(p => EF.Functions.ILike(p.Name, $"%{name}%")).ToListAsync());
    return x;
});

app.MapGet("/api/pathogens/{id}", async (QueryDbContext db, int id) => {
    var result = await db.Pathogens.FirstOrDefaultAsync(p => p.Id == id);
    return result == null ? Results.NotFound() : Results.Ok(result);
});

app.MapPost("/api/pathogens", async (ApplicationDbContext db, Pathogen pathogen) => {
    await db.Pathogens.AddAsync(pathogen);
    await db.SaveChangesAsync();
    return Results.Created($"/api/pathogens/{pathogen.Id}", pathogen);
});

Console.WriteLine($"Current process id is: {System.Diagnostics.Process.GetCurrentProcess().Id}");
app.Run();
