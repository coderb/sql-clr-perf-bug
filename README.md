# SQLCLR scalar functions scale badly in parallel plans

**Reported to Microsoft:**

- [The report on the SQL Server feedback forum](https://feedback.azure.com/d365community/idea/e17dc3c3-8dd0-f111-aad1-6045bdb0c81c). If this affects you too, vote for it there.
- [The question on Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/6049424/sqlclr-scalar-function-spins-on-diag-object-at-hig).

A reproduction for SQL Server 2025: a trivial SQLCLR scalar function, called once per row in a
parallel plan, costs 23 to 36 times as much CPU per call at DOP 24 as at DOP 4, and the query runs
slower at DOP 24 than at DOP 1. Two spinlocks are involved:

- **`DIAG_OBJECT`**, for any SQLCLR scalar call, even `int AddOne(int)`.
- **`SOS_SELIST_SIZED_SLOCK`** and **`SOS_CACHESTORE`**, when the function's parameters are
  declared `nvarchar(max)`. That also costs about 6 times as much on one thread.

The T-SQL equivalent scales normally. The full write-up, with the method, every result and the
questions for Microsoft, is in [docs/report.md](docs/report.md).

CPU per call, in µs, on SQL Server 2025 CU10, 24 schedulers. CU4 gives the same picture.

| Function | DOP 1 | DOP 4 | DOP 8 | DOP 24 | DOP 24 elapsed |
|---|---|---|---|---|---|
| control (T-SQL) | 0.04 | 0.05 | 0.05 | 0.07 | 12 ms |
| `AddOne(int)` | 0.17 | 0.22 | 1.95 | 7.94 | 702 ms (350 ms at DOP 1) |
| `IsMarked`, `nvarchar(4000)` parameters | 0.25 | 0.32 | 1.97 | 7.97 | 715 ms |
| `IsMarked`, `nvarchar(max)` parameters | 1.46 | 2.01 | 4.84 | 24.18 | 2,308 ms |

## Running it

Each script in [`sql/`](sql) is self-contained: the assembly is embedded as hex. Run one as sysadmin
in SSMS or `sqlcmd`, on a server that is otherwise idle, since the spinlock counters are server-wide.

| Script | What it measures | Takes about |
|---|---|---|
| [`repro.sql`](sql/repro.sql) | every function at DOP 1, 2, 4, 8, 16 and the maximum | 3 minutes |
| [`diag.sql`](sql/diag.sql) | every spinlock, latch class and wait type that changes, at DOP 4 and the maximum | 1 minute |
| [`diagconfig.sql`](sql/diagconfig.sql) | `DIAG_OBJECT` with lightweight query profiling and Query Store on and off | 1 minute |

Each script creates database `ClrSpinRepro`, trusts its one assembly by hash with
`sys.sp_add_trusted_assembly`, runs, then drops the database, disconnecting any other session still
in it, and removes the trust. It changes no server setting, and stops before creating anything if
CLR is disabled or `ClrSpinRepro` already exists. If a run stops partway,
[`cleanup.sql`](sql/cleanup.sql) removes what it made.

SSMS runs every batch even after one fails, so a failed check turns on `noexec`: the rest of the
script compiles and none of it runs. Reconnect afterwards, or run `set noexec off`.

## Building

`./build.sh` builds the assembly from [`clr/ClrSpin.cs`](clr/ClrSpin.cs) and regenerates the scripts
from [`sql/parts`](sql/parts). It needs the .NET SDK, which builds the `net472` library on Linux,
macOS or Windows, and Python 3. The build is deterministic and carries no debug information, so the
same source gives the same assembly, hash and scripts.

## Layout

| Path | What it holds |
|---|---|
| `clr/` | the assembly's source and project |
| `sql/parts/` | the script parts: setup, the three tests, teardown |
| `sql/*.sql` | the generated scripts |
| `gen_repro.py`, `build.sh` | the build |
| `docs/report.md` | the report |
| `docs/results/<CU>/` | raw results, one tab-separated file per result set |
