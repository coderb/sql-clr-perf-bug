# SQLCLR scalar functions in parallel plans: CPU per call grows 23 to 36 times from DOP 4 to DOP 24, on spinlocks DIAG_OBJECT and SOS_SELIST_SIZED_SLOCK

## Summary

A trivial SQLCLR scalar function called once per row in a parallel plan costs far more CPU per call
as DOP rises, and past DOP 4 the query also gets slower, not faster. Two separate spinlocks are
involved:

1. **Any SQLCLR scalar call**, even `int AddOne(int)`, spins on **`DIAG_OBJECT`**. From DOP 4 to
   DOP 24, CPU per call grows 23 to 36 times: 0.22 to 7.94 µs for `AddOne`. Elapsed time at DOP 24
   (702 ms) is longer than at DOP 1 (350 ms). Lightweight query profiling and Query Store make no
   difference.
2. **A function declared with `nvarchar(max)` parameters** costs about 6 times as much even at
   DOP 1, and from DOP 2 up spins on **`SOS_SELIST_SIZED_SLOCK`** and **`SOS_CACHESTORE`**. That
   reaches 24.2 µs per call at DOP 24, against 1.46 µs at DOP 1. The same method declared with
   `nvarchar(4000)` parameters spins on neither.

Both hold on CU10 and on CU4; the figures here are CU10's.

The T-SQL equivalent of the same check scales normally and touches neither spinlock.

The second finding matches KB2887899, which describes contention on the same two spinlocks, which
protect CLR procedure cache entries, during spatial index builds at high DOP. That fix covered
spatial index builds on SQL Server 2012 and 2014; the contention still shows for user-written
SQLCLR functions on SQL Server 2025.

We found it in production: a statement calling a SQLCLR function, with `nvarchar(max)` parameters,
for 1.4 million rows. On CU10 it takes 36.1 s of CPU at DOP 24 and 4.4 s at DOP 4, and finishes
faster at DOP 4 (1.0 to 1.1 s against 1.7 s); on CU4, 42.6 s and 4.4 s.

Reported to Microsoft on the SQL Server feedback forum:
<https://feedback.azure.com/d365community/idea/e17dc3c3-8dd0-f111-aad1-6045bdb0c81c>

## Environment

```
Microsoft SQL Server 2025 (RTM-CU10) (KB5125471) - 17.0.5035.5 (X64)
    Oct 15 2026 19:55:26
    Enterprise Developer Edition (64-bit) on Linux (Ubuntu 26.04.1 LTS) <X64>
```

- AMD Ryzen 9 9900X: 12 cores, 24 logical CPUs, 1 socket, 1 NUMA node, 2 L3 cache domains
- 24 visible online schedulers
- max degree of parallelism 0, cost threshold for parallelism 5
- clr enabled 1, clr strict security 0
- SQL Server installed from the Ubuntu 24.04 (noble) package repository; there is none for 26.04.
- The repro database is created with lightweight query profiling on, `LAST_QUERY_PLAN_STATS` off and
  Query Store `READ_WRITE`.

The same tests on CU4 (17.0.4035.5, KB5081495), on the same machine, gave the same picture.

## Reproduction

Three self-contained scripts in [`sql/`](../sql), each run as sysadmin. Each one:

1. creates database `ClrSpinRepro`;
2. trusts a 5 KB `SAFE` assembly by hash (`sys.sp_add_trusted_assembly`), embedded in the script
   as hex;
3. creates the functions below and a 2,000,000-row heap (`ID int`, two `varchar(255)` columns);
4. runs its tests;
5. drops the database and removes the trust.

They change no server setting.

The assembly's whole source:

```csharp
public static class Functions {
    [SqlFunction(IsDeterministic = true, IsPrecise = true,
        DataAccess = DataAccessKind.None, SystemDataAccess = SystemDataAccessKind.None)]
    public static bool? IsMarked(string group, string code) {
        return code == null ? null : code.Length > 3 && code[3] == 'M';
    }

    [SqlFunction(IsDeterministic = true, IsPrecise = true,
        DataAccess = DataAccessKind.None, SystemDataAccess = SystemDataAccessKind.None)]
    public static SqlBoolean IsMarkedSql(SqlString group, SqlString code) {
        if (code.IsNull) {
            return SqlBoolean.Null;
        }
        string s = code.Value;
        return s.Length > 3 && s[3] == 'M';
    }

    [SqlFunction(IsDeterministic = true, IsPrecise = true,
        DataAccess = DataAccessKind.None, SystemDataAccess = SystemDataAccessKind.None)]
    public static int AddOne(int x) {
        return x + 1;
    }
}
```

The functions the tests call:

| Name | SQL declaration | Method |
|---|---|---|
| `IsMarkedMax` | `(@group nvarchar(max), @code nvarchar(max)) returns bit` | `IsMarked` |
| `IsMarked4000` | `(@group nvarchar(4000), @code nvarchar(4000)) returns bit` | `IsMarked` |
| `IsMarkedSql` | `(@group nvarchar(4000), @code nvarchar(4000)) returns bit` | `IsMarkedSql` |
| `AddOne` | `(@x int) returns int` | `AddOne` |
| control | `substring(Code, 4, 1) = 'M'`, no function | |

Each test runs the following through `sp_executesql`. It is repeated 3 times, and runs 2 and 3 are
averaged:

```sql
select @n = count(*) from dbo.T where <predicate>
option (maxdop <N>, use hint ('ENABLE_PARALLEL_PLAN_PREFERENCE'))
```

The figures come from these sources:

- **CPU and DOP used:** `sys.dm_exec_query_stats.last_worker_time` and `last_dop`.
- **Spinlocks and latches:** the change in `sys.dm_os_spinlock_stats` and `sys.dm_os_latch_stats`
  across the run, server-wide.
- **Waits:** the change in `sys.dm_exec_session_wait_stats`, for the session.

The scripts:

- **[`sql/repro.sql`](../sql/repro.sql):** every function at DOP 1, 2, 4, 8, 16 and 24, recording `SOS_SELIST_SIZED_SLOCK`
  and `SOS_CACHESTORE`.
- **[`sql/diag.sql`](../sql/diag.sql):** the functions at DOP 4 and 24, recording every spinlock, latch class and wait type
  that changed.
- **[`sql/diagconfig.sql`](../sql/diagconfig.sql):** `AddOne` at DOP 4 and 24 with the repro database's lightweight query
  profiling and Query Store each on and off.
- **[`sql/threads.sql`](../sql/threads.sql):** `AddOne` at DOP 4, 8, 10, 12, 16, 20 and 24, capturing each run's actual plan
  to divide its rows and CPU among the threads.

The spinlock counters are server-wide, so a busy server adds noise. In our runs, the three runs of
each test agreed closely.

## Results

Three runs of each test on CU10, with CU4's figures noted where they differ most. The raw output is
in [`results/cu10`](results/cu10) and [`results/cu4`](results/cu4). Both sets of runs used a build
of the same source that also carried debug information; the scripts in `sql/` embed a build without
it.

### CPU per call by DOP (`repro.sql`)

µs of CPU per row, from `last_worker_time` / 2,000,000, on CU10:

| Function | DOP 1 | DOP 2 | DOP 4 | DOP 8 | DOP 16 | DOP 24 |
|---|---|---|---|---|---|---|
| control (T-SQL) | 0.04 | 0.04 | 0.05 | 0.05 | 0.07 | 0.07 |
| `IsMarkedMax` | 1.46 | 1.78 | 2.01 | 4.84 | 13.85 | 24.18 |
| `IsMarked4000` | 0.25 | 0.26 | 0.32 | 1.97 | 4.74 | 7.97 |
| `IsMarkedSql` | 0.26 | 0.29 | 0.34 | 1.88 | 4.69 | 7.76 |
| `AddOne` | 0.17 | 0.19 | 0.22 | 1.95 | 4.83 | 7.94 |

On CU4 the same table differs most for `IsMarkedMax` at high DOP: 16.50 µs at DOP 16 and 31.04 µs
at DOP 24.

Elapsed ms, on CU10:

| Function | DOP 1 | DOP 2 | DOP 4 | DOP 8 | DOP 16 | DOP 24 |
|---|---|---|---|---|---|---|
| control (T-SQL) | 85 | 47 | 29 | 17 | 14 | 12 |
| `IsMarkedMax` | 2,979 | 1,878 | 1,067 | 1,475 | 2,016 | 2,308 |
| `IsMarked4000` | 502 | 274 | 189 | 522 | 638 | 715 |
| `IsMarkedSql` | 534 | 296 | 209 | 494 | 630 | 716 |
| `AddOne` | 350 | 193 | 116 | 496 | 629 | 702 |

`SOS_SELIST_SIZED_SLOCK` and `SOS_CACHESTORE` spins (millions) for `IsMarkedMax`, on CU10:

| | DOP 1 | DOP 2 | DOP 4 | DOP 8 | DOP 16 | DOP 24 |
|---|---|---|---|---|---|---|
| `SOS_SELIST_SIZED_SLOCK` | 0 | 0.07 | 0.71 | 59.5 | 487.3 | 605.7 |
| `SOS_CACHESTORE` | 0 | 0.26 | 1.35 | 9.86 | 4.57 | 2.41 |

On CU4, `SOS_SELIST_SIZED_SLOCK` reached 493.0 M at DOP 24, and `SOS_CACHESTORE` peaked at
36.8 M at DOP 8. Both are 0 for every other function, at every DOP, on either CU.

### Which spinlock, at DOP 4 and DOP 24 (`diag.sql`)

The spinlock that spun most, in millions of spins, on CU4:

| Function | DOP 4 | DOP 24 | Collisions at DOP 24 |
|---|---|---|---|
| control | none above 0.001 | none above 0.001 | |
| `AddOne` | `DIAG_OBJECT` 0.50 | `DIAG_OBJECT` 163.3 | 1.70 M |
| `IsMarked4000` | `DIAG_OBJECT` 0.84 | `DIAG_OBJECT` 156.0 | 1.72 M |
| `IsMarkedMax` | `SOS_CACHESTORE` 9.47, `SOS_SELIST_SIZED_SLOCK` 1.89 | `SOS_SELIST_SIZED_SLOCK` 525.2, `SOS_CACHESTORE` 12.0 | 3.41 M |

And on CU10:

| Function | DOP 4 | DOP 24 | Collisions at DOP 24 |
|---|---|---|---|
| control | none above 0.001 | none above 0.001 | |
| `AddOne` | `DIAG_OBJECT` 0.86 | `DIAG_OBJECT` 173.0 | 1.72 M |
| `IsMarked4000` | `DIAG_OBJECT` 0.82 | `DIAG_OBJECT` 158.2 | 1.71 M |
| `IsMarkedMax` | `SOS_CACHESTORE` 2.11, `SOS_SELIST_SIZED_SLOCK` 1.52 | `SOS_SELIST_SIZED_SLOCK` 592.7, `SOS_CACHESTORE` 2.39 | 3.30 M |

`DIAG_OBJECT` is not among the 8 spinlocks that spun most for `IsMarkedMax`, at either DOP, on
either CU.

The waits explain little of the CPU, on either CU:

- **`CXCONSUMER`** is about equal to the elapsed time.
- **`SOS_SCHEDULER_YIELD`** rises from 106 to 145 tasks at DOP 4 to 3,275 to 3,836 at DOP 24 for
  `AddOne` and `IsMarked4000`, and from 1,023 to 1,105 to 9,312 to 10,571 for `IsMarkedMax`.
- **`CLR_MANUAL_EVENT`** appears only for the string functions, the most for `IsMarkedMax`: 1,115 to
  1,339 ms at DOP 4 and 1,742 to 1,846 ms at DOP 24.

No latch class waited more than 41 ms on CU4, or more than 91 ms on CU10, where the 91 ms was the
control's.

### Lightweight query profiling and Query Store (`diagconfig.sql`)

`AddOne` at DOP 24, on CU4 and on CU10:

| Repro database setting | CU4 spins (M) | CU4 CPU ms | CU4 elapsed ms | CU10 spins (M) | CU10 CPU ms | CU10 elapsed ms |
|---|---|---|---|---|---|---|
| profiling on, Query Store `READ_WRITE` | 167.7 | 16,795 | 743 | 186.1 | 15,963 | 702 |
| profiling off | 168.6 | 17,149 | 749 | 187.1 | 15,953 | 697 |
| Query Store off | 169.8 | 17,372 | 759 | 174.1 | 16,033 | 696 |
| both off | 167.1 | 16,885 | 742 | 187.9 | 16,527 | 721 |
| both on again | 169.7 | 17,237 | 747 | 184.6 | 16,381 | 713 |

The spins are `DIAG_OBJECT`'s. At DOP 4 on CU10, the same runs took 437 to 628 ms of CPU.

The Extended Events sessions running during these tests were `system_health`, the
`sp_server_diagnostics` session and `hkenginexesession`. None of them collects an event raised on
each function call.

### How the work divides among threads (`threads.sql`)

Every worker thread is busy for the whole query: on each one, the CPU of the Filter that calls
`AddOne` is within 8 ms of its elapsed time. From DOP 8 up the query takes about the same time,
566 to 659 ms against 136 ms at DOP 4, so each thread added past DOP 4 adds CPU and no speed. That
includes DOP 10 and 12, at or under the machine's 12 cores.

The rows divide close to evenly. The scan hands them out in chunks of 30,464 rows, and every thread
gets a whole number of chunks, except the one that takes the last, partial chunk. At DOP 24 that
is 2 or 3 chunks per thread, which is all the spread at that DOP comes from.

`AddOne` on CU10, from run 2 of two at each DOP:

| DOP | Rows per thread | CPU per thread (ms) | CPU (ms) | CPU per call (µs) | Elapsed (ms) |
|---|---|---|---|---|---|
| 4 | 487,424 to 517,888 | 133 to 135 | 535 | 0.27 | 136 |
| 8 | 233,088 to 274,176 | 542 to 571 | 4,506 | 2.25 | 572 |
| 10 | 152,320 to 243,712 | 549 to 565 | 5,597 | 2.80 | 566 |
| 12 | 152,320 to 182,784 | 539 to 580 | 6,822 | 3.41 | 580 |
| 16 | 91,392 to 152,320 | 560 to 608 | 9,443 | 4.72 | 609 |
| 20 | 91,392 to 121,856 | 583 to 652 | 12,643 | 6.32 | 653 |
| 24 | 60,928 to 91,392 | 532 to 659 | 15,073 | 7.54 | 659 |

The CPU is the Filter operator's on each worker thread, which includes the scan beneath it; the
scan alone took 14 to 57 ms per thread. Elapsed is the coordinator thread's, at the top of the plan.
The capture adds per-operator timing to the runs it watches: over two runs, the CPU summed to
between 5% below and 21% above what `repro.sql` measured at the same DOP, so these figures compare
with one another more closely than with the tables above. The row counts are exact.

## What we would like to know

1. What takes `DIAG_OBJECT` on each SQLCLR scalar call, and whether that work can be avoided or
   partitioned per scheduler.
2. Whether `nvarchar(max)` arguments to SQLCLR functions taking `SOS_SELIST_SIZED_SLOCK` and
   `SOS_CACHESTORE` on each call is the contention KB2887899 fixed for spatial index builds, and
   whether that fix can reach user-written functions.
3. Until then, whether capping DOP for statements that call SQLCLR functions heavily, and
   declaring their string parameters with a size rather than `max`, is the recommended
   mitigation.

The scripts, the C# source, the build script and the raw results are all in this repository. We can
run further captures, such as `spinlock_backoff` with call stacks, if that helps.
