-- Diagnostic: whether the contention follows the function or the query. AddOne's rows are split by ID
-- across 1, 4 and 24 separately declared SQL functions over the same method, at DOP 4 up to the machine's
-- maximum. If each function had its own lock, more copies would spread the spinning; if the query's
-- threads share one, the copies change nothing.

-- AddOne_1 to AddOne_24, each its own function over the one method
declare @k int = 1, @ddl nvarchar(max);
while @k <= 24 begin
    set @ddl = N'create function dbo.AddOne_' + convert(nvarchar(4), @k) + N'(@x int) returns int
as external name ClrSpin.[ClrSpin.Functions].AddOne;';
    exec (@ddl);
    set @k += 1;
end
go

create table #r (
    Copies int not null,
    DopAsked int not null,
    Run int not null,
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

declare @copies table (Copies int not null primary key);
insert @copies values (1), (4), (24);

declare @maxdop int = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE');
declare @dops table (Dop int not null primary key);
insert @dops select distinct d from (values (4), (8), (12), (16), (20), (@maxdop)) v(d) where d <= @maxdop;

declare @n int, @c int, @dop int, @run int, @k int, @predicate nvarchar(max), @sql nvarchar(max), @marker nvarchar(100);
declare @t0 datetime2(7), @elapsed int;

set @c = (select min(Copies) from @copies);
while @c is not null begin
    -- each row calls exactly one copy, the one its ID picks; one copy goes through the same case
    set @predicate = N'case ID % ' + convert(nvarchar(4), @c);
    set @k = 0;
    while @k < @c begin
        set @predicate += N' when ' + convert(nvarchar(4), @k) + N' then dbo.AddOne_' + convert(nvarchar(4), @k + 1) + N'(ID)';
        set @k += 1;
    end
    set @predicate += N' end = 0';

    set @dop = (select min(Dop) from @dops);
    while @dop is not null begin
        set @run = 1;
        while @run <= 3 begin
            set @marker = N'/*clrspin split copies' + convert(nvarchar(4), @c) + N' dop' + convert(nvarchar(4), @dop) + N' run' + convert(nvarchar(4), @run) + N'*/';
            set @sql = N'select @n = count(*) ' + @marker + N' from dbo.T where ' + @predicate
                + N' option (maxdop ' + convert(nvarchar(4), @dop) + N', use hint (''ENABLE_PARALLEL_PLAN_PREFERENCE''))';

            truncate table #spin0;
            insert #spin0 select name, spins, collisions from sys.dm_os_spinlock_stats;
            set @t0 = sysdatetime();
            exec sys.sp_executesql @sql, N'@n int output', @n = @n output;
            set @elapsed = datediff(millisecond, @t0, sysdatetime());

            insert #r
            select
                @c, @dop, @run,
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
    set @c = (select min(Copies) from @copies where Copies > @c);
end
go

-- run 1 of each warms the plan; runs 2 and 3 are averaged
select
    Copies,
    DopAsked,
    DopUsed = max(DopUsed),
    ElapsedMs = avg(ElapsedMs),
    CpuMs = avg(CpuMs),
    CpuUsPerRow = convert(decimal(9, 2), avg(CpuMs) * 1000.0 / 2000000),
    DiagSpins = avg(DiagSpins),
    DiagCollisions = avg(DiagCollisions),
    TopSpinlock = max(TopSpinlock),
    TopSpins = avg(TopSpins)
from #r
where Run > 1
group by Copies, DopAsked
order by Copies, DopAsked;

-- Each copy's call count would show the split happened, but sys.dm_exec_function_stats lists no CLR
-- function on SQL Server 2025 CU10, only T-SQL ones, though its documentation says it covers both. The
-- split rests on case evaluating only the branch that matches, so each row calls the one copy its ID
-- picks.
-- select
--     FunctionName = object_name(fs.object_id),
--     fs.execution_count
-- from sys.dm_exec_function_stats fs
-- where fs.database_id = db_id() and object_name(fs.object_id) like N'AddOne[_]%'
-- order by convert(int, substring(object_name(fs.object_id), 8, 4));

select * from #r order by Copies, DopAsked, Run;
go
