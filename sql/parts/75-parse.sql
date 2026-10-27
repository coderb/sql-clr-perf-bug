-- Diagnostic: a real parser, taken as a string and as a streamed SqlChars, over descriptions shaped like
-- a parcel table's legal descriptions: half are 56 characters or fewer, 1 in 100 over 566, 1 in 1,000
-- over 1,651, the longest 5,120, and 1 in 50 ends in a match. CPU, spins and the CLR's own count of
-- memory allocated, at DOP 1 up to the machine's maximum, after a check that every variant returns what
-- the string parser does. The variants run interleaved, as in the trivial check's part.

create function dbo.ParseMaxAll(@s nvarchar(max), @startDelim nvarchar(max), @endDelim nvarchar(max)) returns nvarchar(max)
as external name ClrSpin.[ClrSpin.Functions].ParseFromEnd;
go
create function dbo.ParseMaxText(@s nvarchar(max), @startDelim nvarchar(4000), @endDelim nvarchar(4000)) returns nvarchar(max)
as external name ClrSpin.[ClrSpin.Functions].ParseFromEnd;
go
create function dbo.ParseCharsText(@s nvarchar(max), @startDelim nvarchar(4000), @endDelim nvarchar(4000)) returns nvarchar(max)
as external name ClrSpin.[ClrSpin.Functions].ParseFromEndChars;
go
create function dbo.Parse4000(@s nvarchar(4000), @startDelim nvarchar(4000), @endDelim nvarchar(4000)) returns nvarchar(4000)
as external name ClrSpin.[ClrSpin.Functions].ParseFromEnd;
go

create table dbo.D (
    ID int not null,
    Description varchar(5120) not null
);

with N as (
    select top (2000000) n = row_number() over (order by (select null))
    from sys.all_columns a cross join sys.all_columns b cross join sys.all_columns c
), L as (
    select
        n,
        len = case
            when n % 1000 < 500 then 20 + n % 37
            when n % 1000 < 900 then 57 + n % 109
            when n % 1000 < 990 then 166 + n % 401
            when n % 1000 < 999 then 567 + n % 1085
            else 1652 + n % 3469
        end
    from N
)
insert dbo.D with (tablock)
select
    n,
    case
        when n % 50 = 0 then left(replicate(convert(varchar(max), 'LOT 5 BLK 3 '), len / 12 + 1), len - 20) + ' SUNNY HILLS 2ND ADD'
        else left(replicate(convert(varchar(max), 'LOT 5 BLK 3 '), len / 12 + 1), len)
    end
from L;
go

-- every variant must return what the string parser returns; Parse4000 is expected to differ only on the
-- few descriptions over 4,000 characters, which its parameter cuts short
select
    Rows = count(*),
    Matches = sum(case when dbo.ParseMaxAll(Description, N' ', N'ND ADD') is not null then 1 else 0 end),
    MaxTextDiffers = sum(case when isnull(dbo.ParseMaxText(Description, N' ', N'ND ADD'), N'~') <> isnull(dbo.ParseMaxAll(Description, N' ', N'ND ADD'), N'~') then 1 else 0 end),
    CharsDiffers = sum(case when isnull(dbo.ParseCharsText(Description, N' ', N'ND ADD'), N'~') <> isnull(dbo.ParseMaxAll(Description, N' ', N'ND ADD'), N'~') then 1 else 0 end),
    Parse4000Differs = sum(case when isnull(dbo.Parse4000(Description, N' ', N'ND ADD'), N'~') <> isnull(dbo.ParseMaxAll(Description, N' ', N'ND ADD'), N'~') then 1 else 0 end),
    Over4000 = sum(case when len(Description) > 4000 then 1 else 0 end)
from dbo.D
option (maxdop 4);
go

create table #p (
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
select top 0 name, spins into #pspin0 from sys.dm_os_spinlock_stats;
go

declare @variants table (Ord int not null primary key, Variant varchar(20) not null, Fn nvarchar(100) not null);
insert @variants values
    (1, 'ParseMaxAll', N'dbo.ParseMaxAll'),
    (2, 'ParseMaxText', N'dbo.ParseMaxText'),
    (3, 'ParseCharsText', N'dbo.ParseCharsText'),
    (4, 'Parse4000', N'dbo.Parse4000');

declare @maxdop int = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE');
declare @dops table (Dop int not null primary key);
insert @dops select distinct d from (values (1), (4), (8), (@maxdop)) v(d) where d <= @maxdop;

declare @variant varchar(20), @fn nvarchar(100), @dop int, @run int, @sql nvarchar(max), @marker nvarchar(100);
declare @n int, @t0 datetime2(7), @elapsed int, @alloc0 bigint;

declare c cursor local fast_forward for
select V.Variant, V.Fn, D.Dop, R.Run
from @variants V cross join @dops D cross join (values (1), (2), (3), (4), (5)) R(Run)
order by R.Run, D.Dop, (V.Ord + R.Run) % 4;
open c;
fetch c into @variant, @fn, @dop, @run;
while @@fetch_status = 0 begin
    set @marker = N'/*clrspin parse ' + @variant + N' dop' + convert(nvarchar(4), @dop) + N' run' + convert(nvarchar(4), @run) + N'*/';
    set @sql = N'select @n = count(*) ' + @marker + N' from dbo.D where ' + @fn + N'(Description, N'' '', N''ND ADD'') is not null'
        + N' option (maxdop ' + convert(nvarchar(4), @dop) + N', use hint (''ENABLE_PARALLEL_PLAN_PREFERENCE''))';

    truncate table #pspin0;
    insert #pspin0 select name, spins from sys.dm_os_spinlock_stats;
    set @alloc0 = (select sum(total_allocated_memory_kb) from sys.dm_clr_appdomains where db_id = db_id());
    set @t0 = sysdatetime();
    exec sys.sp_executesql @sql, N'@n int output', @n = @n output;
    set @elapsed = datediff(millisecond, @t0, sysdatetime());

    insert #p
    select
        @variant, @dop, @run,
        (select top 1 qs.last_dop from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
            where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
        @elapsed,
        (select top 1 qs.last_worker_time / 1000 from sys.dm_exec_query_stats qs cross apply sys.dm_exec_sql_text(qs.sql_handle) st
            where st.text like N'%' + @marker + N'%' and st.text not like N'%dm_exec_query_stats%'),
        (select sum(total_allocated_memory_kb) from sys.dm_clr_appdomains where db_id = db_id()) - @alloc0,
        (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join #pspin0 s0 on s0.name = s.name where s.name = 'SOS_SELIST_SIZED_SLOCK'),
        (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join #pspin0 s0 on s0.name = s.name where s.name = 'SOS_CACHESTORE'),
        (select s.spins - s0.spins from sys.dm_os_spinlock_stats s join #pspin0 s0 on s0.name = s.name where s.name = 'DIAG_OBJECT');

    fetch c into @variant, @fn, @dop, @run;
end
close c;
deallocate c;
go

-- pass 1 warms the plans; passes 2 to 5 are averaged, beside each point's lowest and highest CPU
select
    Variant,
    DopAsked,
    DopUsed = max(DopUsed),
    ElapsedMs = avg(ElapsedMs),
    CpuMs = avg(CpuMs),
    MinCpuMs = min(CpuMs),
    MaxCpuMs = max(CpuMs),
    CpuUsPerRow = convert(decimal(9, 2), avg(CpuMs) * 1000.0 / 2000000),
    AllocKb = avg(AllocKb),
    AllocBytesPerRow = convert(decimal(9, 1), avg(AllocKb) * 1024.0 / 2000000),
    SelistSpins = avg(SelistSpins),
    CachestoreSpins = avg(CachestoreSpins),
    DiagSpins = avg(DiagSpins)
from #p
where Run > 1
group by Variant, DopAsked
order by min(case Variant when 'ParseMaxAll' then 1 when 'ParseMaxText' then 2 when 'ParseCharsText' then 3 else 4 end), DopAsked;

select * from #p order by Variant, DopAsked, Run;
go
