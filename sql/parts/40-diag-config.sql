-- Diagnostic: whether a database diagnostics feature takes the DIAG_OBJECT spinlock on every CLR call.
-- AddOne at DOP 4 and the machine's maximum under five settings of this scratch database only:
-- lightweight query profiling and Query Store each on and off, then both back on to check for drift.
-- Both are database settings, so nothing outside ClrSpinRepro changes.

-- the settings the new database started with, before any change
select
    Setting = 'initial',
    Lwp = (select convert(varchar(10), value) from sys.database_scoped_configurations where name = 'LIGHTWEIGHT_QUERY_PROFILING'),
    LastPlanStats = (select convert(varchar(10), value) from sys.database_scoped_configurations where name = 'LAST_QUERY_PLAN_STATS'),
    QueryStore = (select actual_state_desc from sys.database_query_store_options);

create table #r (
    Config varchar(20) not null,
    DopAsked int not null,
    Run int not null,
    Lwp varchar(10) null,
    QueryStore nvarchar(60) null,
    DopUsed int null,
    ElapsedMs int not null,
    CpuMs int null,
    DiagSpins bigint null,
    DiagCollisions bigint null,
    TopSpinlock nvarchar(256) null,
    TopSpins bigint null
);
select top 0 name, spins, collisions into #spin0 from sys.dm_os_spinlock_stats;
go

declare @configs table (Ord int not null primary key, Config varchar(20) not null, Lwp varchar(3) not null, Qs varchar(3) not null);
insert @configs values
    (1, 'both_on', 'ON', 'ON'),
    (2, 'lwp_off', 'OFF', 'ON'),
    (3, 'qs_off', 'ON', 'OFF'),
    (4, 'both_off', 'OFF', 'OFF'),
    (5, 'both_on_again', 'ON', 'ON');

declare @maxdop int = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE');
declare @dops table (Dop int not null primary key);
insert @dops select distinct d from (values (4), (@maxdop)) v(d) where d <= @maxdop;

declare @ord int = 1, @config varchar(20), @lwp varchar(3), @qs varchar(3);
declare @dop int, @run int, @sql nvarchar(max), @marker nvarchar(100);
declare @n int, @t0 datetime2(7), @elapsed int;

while @ord <= 5 begin
    select @config = Config, @lwp = Lwp, @qs = Qs from @configs where Ord = @ord;
    exec (N'alter database scoped configuration set LIGHTWEIGHT_QUERY_PROFILING = ' + @lwp);
    exec (N'alter database current set query_store = ' + @qs);

    set @dop = (select min(Dop) from @dops);
    while @dop is not null begin
        set @run = 1;
        while @run <= 3 begin
            set @marker = N'/*clrspin cfg ' + @config + N' dop' + convert(nvarchar(4), @dop) + N' run' + convert(nvarchar(4), @run) + N'*/';
            set @sql = N'select @n = count(*) ' + @marker + N' from dbo.T where dbo.AddOne(ID) = 0'
                + N' option (maxdop ' + convert(nvarchar(4), @dop) + N', use hint (''ENABLE_PARALLEL_PLAN_PREFERENCE''))';

            truncate table #spin0;
            insert #spin0 select name, spins, collisions from sys.dm_os_spinlock_stats;
            set @t0 = sysdatetime();
            exec sys.sp_executesql @sql, N'@n int output', @n = @n output;
            set @elapsed = datediff(millisecond, @t0, sysdatetime());

            insert #r
            select
                @config, @dop, @run,
                (select convert(varchar(10), value) from sys.database_scoped_configurations where name = 'LIGHTWEIGHT_QUERY_PROFILING'),
                (select actual_state_desc from sys.database_query_store_options),
                (select top 1 qs.last_dop from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
                    where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
                @elapsed,
                (select top 1 qs.last_worker_time / 1000 from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
                    where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
                (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join #spin0 s0 on s0.name = s.name where s.name = 'DIAG_OBJECT'),
                (select s.collisions - s0.collisions from sys.dm_os_spinlock_stats s join #spin0 s0 on s0.name = s.name where s.name = 'DIAG_OBJECT'),
                T.name, T.d
            from (
                select top 1 s.name, d = s.spins - s0.spins
                from sys.dm_os_spinlock_stats s join #spin0 s0 on s0.name = s.name
                order by s.spins - s0.spins desc
            ) T;

            set @run += 1;
        end
        set @dop = (select min(Dop) from @dops where Dop > @dop);
    end
    set @ord += 1;
end
go

-- run 1 of each warms the plan; runs 2 and 3 are averaged
select
    Config,
    DopAsked,
    Lwp = max(Lwp),
    QueryStore = max(QueryStore),
    DopUsed = max(DopUsed),
    ElapsedMs = avg(ElapsedMs),
    CpuMs = avg(CpuMs),
    DiagSpins = avg(DiagSpins),
    DiagCollisions = avg(DiagCollisions),
    TopSpinlock = max(TopSpinlock),
    TopSpins = avg(TopSpins)
from #r
where Run > 1
group by Config, DopAsked
order by min(case Config when 'both_on' then 1 when 'lwp_off' then 2 when 'qs_off' then 3 when 'both_off' then 4 else 5 end), DopAsked;

select * from #r order by Config, DopAsked, Run;
go
