-- Diagnostic: whether an nvarchar(max) argument's cost depends on the type the method takes it as. The
-- same check, with nvarchar(max) parameters, taken as a string, as a SqlString and as a SqlChars, which
-- streams the value rather than copy it; nvarchar(4000) parameters taken as a string set the floor. At
-- DOP 1 up to the machine's maximum, recording the spinlocks an nvarchar(max) argument spins on and the
-- CLR's own count of memory allocated.

create function dbo.IsMarkedSqlMax(@group nvarchar(max), @code nvarchar(max)) returns bit
as external name ClrSpin.[ClrSpin.Functions].IsMarkedSql;
go
create function dbo.IsMarkedCharsMax(@group nvarchar(max), @code nvarchar(max)) returns bit
as external name ClrSpin.[ClrSpin.Functions].IsMarkedChars;
go

create table #r (
    Variant varchar(20) not null,
    DopAsked int not null,
    Run int not null,
    DopUsed int null,
    ElapsedMs int not null,
    CpuMs int null,
    AllocKb bigint null,
    SelistSpins bigint null,
    CachestoreSpins bigint null,
    DiagSpins bigint null
);
select top 0 name, spins into #spin0 from sys.dm_os_spinlock_stats;
go

declare @variants table (Ord int not null primary key, Variant varchar(20) not null, Predicate nvarchar(200) not null);
insert @variants values
    (1, 'IsMarkedMax', N'dbo.IsMarkedMax(GroupName, Code) = 1'),
    (2, 'IsMarkedSqlMax', N'dbo.IsMarkedSqlMax(GroupName, Code) = 1'),
    (3, 'IsMarkedCharsMax', N'dbo.IsMarkedCharsMax(GroupName, Code) = 1'),
    (4, 'IsMarked4000', N'dbo.IsMarked4000(GroupName, Code) = 1');

declare @maxdop int = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE');
declare @dops table (Dop int not null primary key);
insert @dops select distinct d from (values (1), (4), (8), (@maxdop)) v(d) where d <= @maxdop;

declare @variant varchar(20), @predicate nvarchar(200), @dop int, @run int, @sql nvarchar(max), @marker nvarchar(100);
declare @n int, @t0 datetime2(7), @elapsed int, @alloc0 bigint;

declare c cursor local fast_forward for
select V.Variant, V.Predicate, D.Dop, R.Run
from @variants V cross join @dops D cross join (values (1), (2), (3)) R(Run)
order by V.Ord, D.Dop, R.Run;
open c;
fetch c into @variant, @predicate, @dop, @run;
while @@fetch_status = 0 begin
    set @marker = N'/*clrspin sqlchars ' + @variant + N' dop' + convert(nvarchar(4), @dop) + N' run' + convert(nvarchar(4), @run) + N'*/';
    set @sql = N'select @n = count(*) ' + @marker + N' from dbo.T where ' + @predicate
        + N' option (maxdop ' + convert(nvarchar(4), @dop) + N', use hint (''ENABLE_PARALLEL_PLAN_PREFERENCE''))';

    truncate table #spin0;
    insert #spin0 select name, spins from sys.dm_os_spinlock_stats;
    set @alloc0 = (select sum(total_allocated_memory_kb) from sys.dm_clr_appdomains where db_id = db_id());
    set @t0 = sysdatetime();
    exec sys.sp_executesql @sql, N'@n int output', @n = @n output;
    set @elapsed = datediff(millisecond, @t0, sysdatetime());

    insert #r
    select
        @variant, @dop, @run,
        (select top 1 qs.last_dop from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
            where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
        @elapsed,
        (select top 1 qs.last_worker_time / 1000 from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
            where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
        (select sum(total_allocated_memory_kb) from sys.dm_clr_appdomains where db_id = db_id()) - @alloc0,
        (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join #spin0 s0 on s0.name = s.name where s.name = 'SOS_SELIST_SIZED_SLOCK'),
        (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join #spin0 s0 on s0.name = s.name where s.name = 'SOS_CACHESTORE'),
        (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join #spin0 s0 on s0.name = s.name where s.name = 'DIAG_OBJECT');

    fetch c into @variant, @predicate, @dop, @run;
end
close c;
deallocate c;
go

-- run 1 of each warms the plan; runs 2 and 3 are averaged
select
    Variant,
    DopAsked,
    DopUsed = max(DopUsed),
    ElapsedMs = avg(ElapsedMs),
    CpuMs = avg(CpuMs),
    CpuUsPerRow = convert(decimal(9, 2), avg(CpuMs) * 1000.0 / 2000000),
    AllocKb = avg(AllocKb),
    AllocBytesPerRow = convert(decimal(9, 1), avg(AllocKb) * 1024.0 / 2000000),
    SelistSpins = avg(SelistSpins),
    CachestoreSpins = avg(CachestoreSpins),
    DiagSpins = avg(DiagSpins)
from #r
where Run > 1
group by Variant, DopAsked
order by min(case Variant when 'IsMarkedMax' then 1 when 'IsMarkedSqlMax' then 2 when 'IsMarkedCharsMax' then 3 else 4 end), DopAsked;

select * from #r order by Variant, DopAsked, Run;
go
