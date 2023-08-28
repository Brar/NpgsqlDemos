using Microsoft.EntityFrameworkCore;

namespace LoadBalancing
{
    public class ApplicationDbContext : DbContext
    {
        public ApplicationDbContext(DbContextOptions<ApplicationDbContext> options) : base (options) { }

        public DbSet<Pathogen> Pathogens {get; set;} = default!;
    }

    public class QueryDbContext : DbContext
    {
        public QueryDbContext(DbContextOptions<QueryDbContext> options) : base (options) { }

        public IQueryable<Pathogen> Pathogens => Set<Pathogen>().AsNoTracking();

        public override int SaveChanges() => throw new InvalidOperationException("This context is read-only.");

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            modelBuilder.Entity<Pathogen>(e => e.ToTable("pathogens") /* Why is this even necessary? */);
        }
    }

    public class LongRunningQueryDbContext : DbContext
    {
        public LongRunningQueryDbContext(DbContextOptions<LongRunningQueryDbContext> options) : base (options) { }

        public IQueryable<Pathogen> Pathogens => Set<Pathogen>().FromSqlRaw("SELECT * FROM pathogens p, pg_sleep(20)").AsNoTracking();

        public override int SaveChanges() => throw new InvalidOperationException("This context is read-only.");

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            modelBuilder.Entity<Pathogen>(e => e.ToTable("pathogens") /* Why is this even necessary? */);
        }
    }

    public class Pathogen
    {
        public int Id { get; set; }
        public required string Name { get; set; }
    }
}
