create table #r (
    Variant varchar(20) not null,
    DopAsked int not null,
    Run int not null,
    DopUsed int null,
    Rows int not null,
    ElapsedMs int not null,
    CpuMs int null,
    SelistSpins bigint not null,
    SelistCollisions bigint not null,
    CachestoreSpins bigint not null
);
go

declare @variants table (Ord int not null, Variant varchar(20) not null, Predicate nvarchar(200) not null);
insert @variants values
    (1, 'control', N'substring(Code, 4, 1) = ''M'''),
    (2, 'IsMarkedMax', N'dbo.IsMarkedMax(GroupName, Code) = 1'),
    (3, 'IsMarked4000', N'dbo.IsMarked4000(GroupName, Code) = 1'),
    (4, 'IsMarkedSql', N'dbo.IsMarkedSql(GroupName, Code) = 1'),
    (5, 'AddOne', N'dbo.AddOne(ID) = 0');

declare @maxdop int = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE');
declare @dops table (Dop int not null primary key);
insert @dops select distinct d from (values (1), (2), (4), (8), (16), (@maxdop)) v(d) where d <= @maxdop;

declare @variant varchar(20), @predicate nvarchar(200), @dop int, @run int, @sql nvarchar(max), @marker nvarchar(100);
declare @n int, @t0 datetime2(7), @elapsed int;
declare @s0 table (name nvarchar(256) not null, spins bigint not null, collisions bigint not null);

declare c cursor local fast_forward for
select V.Variant, V.Predicate, D.Dop, R.Run
from @variants V cross join @dops D cross join (values (1), (2), (3)) R(Run)
order by V.Ord, D.Dop, R.Run;
open c;
fetch c into @variant, @predicate, @dop, @run;
while @@fetch_status = 0 begin
    set @marker = N'/*clrspin ' + @variant + N' dop' + convert(nvarchar(4), @dop) + N' run' + convert(nvarchar(4), @run) + N'*/';
    set @sql = N'select @n = count(*) ' + @marker + N' from dbo.T where ' + @predicate
        + N' option (maxdop ' + convert(nvarchar(4), @dop) + N', use hint (''ENABLE_PARALLEL_PLAN_PREFERENCE''))';

    delete @s0;
    insert @s0 select name, spins, collisions from sys.dm_os_spinlock_stats where name in ('SOS_SELIST_SIZED_SLOCK', 'SOS_CACHESTORE');
    set @t0 = sysdatetime();
    exec sys.sp_executesql @sql, N'@n int output', @n = @n output;
    set @elapsed = datediff(millisecond, @t0, sysdatetime());

    insert #r
    select
        @variant, @dop, @run,
        (select top 1 qs.last_dop from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
            where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
        @n, @elapsed,
        (select top 1 qs.last_worker_time / 1000 from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
            where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
        (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join @s0 s0 on s0.name = s.name collate database_default where s.name = 'SOS_SELIST_SIZED_SLOCK'),
        (select s.collisions - s0.collisions from sys.dm_os_spinlock_stats s join @s0 s0 on s0.name = s.name collate database_default where s.name = 'SOS_SELIST_SIZED_SLOCK'),
        (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join @s0 s0 on s0.name = s.name collate database_default where s.name = 'SOS_CACHESTORE');

    fetch c into @variant, @predicate, @dop, @run;
end
close c;
deallocate c;
go

-- run 1 of each pair warms the plan and the data; runs 2 and 3 are averaged
select
    Variant,
    DopAsked,
    DopUsed = max(DopUsed),
    Rows = max(Rows),
    ElapsedMs = avg(ElapsedMs),
    CpuMs = avg(CpuMs),
    CpuUsPerRow = convert(decimal(10,2), avg(CpuMs) * 1000.0 / 2000000),
    SelistSpins = avg(SelistSpins),
    SelistCollisions = avg(SelistCollisions),
    CachestoreSpins = avg(CachestoreSpins)
from #r
where Run > 1
group by Variant, DopAsked
order by min(case Variant when 'control' then 1 when 'IsMarkedMax' then 2 when 'IsMarked4000' then 3 when 'IsMarkedSql' then 4 else 5 end), DopAsked;

select * from #r order by Variant, DopAsked, Run;
go
