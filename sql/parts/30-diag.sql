-- Diagnostic: what contends when CLR calls run on many threads. For each function at DOP 4 and the
-- machine's maximum, the change in every spinlock, latch class and wait type across one run: spinlocks
-- and latches server-wide, waits for this session only, which counts its parallel workers' waits too.
create table #r (
    Variant varchar(20) not null,
    DopAsked int not null,
    Run int not null,
    DopUsed int null,
    ElapsedMs int not null,
    CpuMs int null
);
select top 0 Variant = convert(varchar(20), ''), DopAsked = 0, Run = 0, name, spins, collisions, backoffs, sleep_time into #spin from sys.dm_os_spinlock_stats;
select top 0 Variant = convert(varchar(20), ''), DopAsked = 0, Run = 0, latch_class, waiting_requests_count, wait_time_ms into #latch from sys.dm_os_latch_stats;
select top 0 Variant = convert(varchar(20), ''), DopAsked = 0, Run = 0, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms into #wait from sys.dm_exec_session_wait_stats;
select top 0 name, spins, collisions, backoffs, sleep_time into #spin0 from sys.dm_os_spinlock_stats;
select top 0 latch_class, waiting_requests_count, wait_time_ms into #latch0 from sys.dm_os_latch_stats;
select top 0 wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms into #wait0 from sys.dm_exec_session_wait_stats;
go

declare @variants table (Ord int not null, Variant varchar(20) not null, Predicate nvarchar(200) not null);
insert @variants values
    (1, 'control', N'substring(Code, 4, 1) = ''M'''),
    (2, 'IsMarkedMax', N'dbo.IsMarkedMax(GroupName, Code) = 1'),
    (3, 'IsMarked4000', N'dbo.IsMarked4000(GroupName, Code) = 1'),
    (4, 'AddOne', N'dbo.AddOne(ID) = 0');

declare @maxdop int = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE');
declare @dops table (Dop int not null primary key);
insert @dops select distinct d from (values (4), (@maxdop)) v(d) where d <= @maxdop;

declare @variant varchar(20), @predicate nvarchar(200), @dop int, @run int, @sql nvarchar(max), @marker nvarchar(100);
declare @n int, @t0 datetime2(7), @elapsed int;

declare c cursor local fast_forward for
select V.Variant, V.Predicate, D.Dop, R.Run
from @variants V cross join @dops D cross join (values (1), (2), (3)) R(Run)
order by V.Ord, D.Dop, R.Run;
open c;
fetch c into @variant, @predicate, @dop, @run;
while @@fetch_status = 0 begin
    set @marker = N'/*clrspin diag ' + @variant + N' dop' + convert(nvarchar(4), @dop) + N' run' + convert(nvarchar(4), @run) + N'*/';
    set @sql = N'select @n = count(*) ' + @marker + N' from dbo.T where ' + @predicate
        + N' option (maxdop ' + convert(nvarchar(4), @dop) + N', use hint (''ENABLE_PARALLEL_PLAN_PREFERENCE''))';

    truncate table #spin0;
    truncate table #latch0;
    truncate table #wait0;
    insert #spin0 select name, spins, collisions, backoffs, sleep_time from sys.dm_os_spinlock_stats;
    insert #latch0 select latch_class, waiting_requests_count, wait_time_ms from sys.dm_os_latch_stats;
    insert #wait0 select wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms from sys.dm_exec_session_wait_stats where session_id = @@spid;
    set @t0 = sysdatetime();
    exec sys.sp_executesql @sql, N'@n int output', @n = @n output;
    set @elapsed = datediff(millisecond, @t0, sysdatetime());

    insert #spin
    select @variant, @dop, @run, s.name, s.spins - isnull(s0.spins, 0), s.collisions - isnull(s0.collisions, 0), s.backoffs - isnull(s0.backoffs, 0), s.sleep_time - isnull(s0.sleep_time, 0)
    from sys.dm_os_spinlock_stats s left join #spin0 s0 on s0.name = s.name
    where s.spins - isnull(s0.spins, 0) > 0;
    insert #latch
    select @variant, @dop, @run, l.latch_class, l.waiting_requests_count - isnull(l0.waiting_requests_count, 0), l.wait_time_ms - isnull(l0.wait_time_ms, 0)
    from sys.dm_os_latch_stats l left join #latch0 l0 on l0.latch_class = l.latch_class
    where l.waiting_requests_count - isnull(l0.waiting_requests_count, 0) > 0;
    insert #wait
    select @variant, @dop, @run, w.wait_type, w.waiting_tasks_count - isnull(w0.waiting_tasks_count, 0), w.wait_time_ms - isnull(w0.wait_time_ms, 0), w.signal_wait_time_ms - isnull(w0.signal_wait_time_ms, 0)
    from sys.dm_exec_session_wait_stats w left join #wait0 w0 on w0.wait_type = w.wait_type
    where w.session_id = @@spid and w.waiting_tasks_count - isnull(w0.waiting_tasks_count, 0) > 0;

    insert #r
    select
        @variant, @dop, @run,
        (select top 1 qs.last_dop from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
            where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
        @elapsed,
        (select top 1 qs.last_worker_time / 1000 from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
            where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%');

    fetch c into @variant, @predicate, @dop, @run;
end
close c;
deallocate c;
go

-- run 1 of each warms the plan and the data; runs 2 and 3 are averaged
select Variant, DopAsked, DopUsed = max(DopUsed), ElapsedMs = avg(ElapsedMs), CpuMs = avg(CpuMs)
from #r where Run > 1
group by Variant, DopAsked
order by Variant, DopAsked;

-- the 8 spinlocks that spun most for each function and DOP
select Variant, DopAsked, name, Spins, Collisions, Backoffs, SleepTime
from (
    select Variant, DopAsked, name, Spins = avg(spins), Collisions = avg(collisions), Backoffs = avg(backoffs), SleepTime = avg(sleep_time),
        rn = row_number() over (partition by Variant, DopAsked order by avg(spins) desc)
    from #spin where Run > 1
    group by Variant, DopAsked, name
) x
where rn <= 8
order by Variant, DopAsked, Spins desc;

-- the 8 waits that took longest for each function and DOP, this session and its parallel workers
select Variant, DopAsked, wait_type, Tasks, WaitMs, SignalMs
from (
    select Variant, DopAsked, wait_type, Tasks = avg(waiting_tasks_count), WaitMs = avg(wait_time_ms), SignalMs = avg(signal_wait_time_ms),
        rn = row_number() over (partition by Variant, DopAsked order by avg(wait_time_ms) desc, avg(waiting_tasks_count) desc)
    from #wait where Run > 1
    group by Variant, DopAsked, wait_type
) x
where rn <= 8
order by Variant, DopAsked, WaitMs desc;

-- latch classes that had waits, server-wide
select Variant, DopAsked, latch_class, Requests = avg(waiting_requests_count), WaitMs = avg(wait_time_ms)
from #latch where Run > 1
group by Variant, DopAsked, latch_class
order by Variant, DopAsked, WaitMs desc;
go
