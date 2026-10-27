-- Diagnostic: how the rows, and the CPU spent on them, divide among the threads of a parallel plan.
-- AddOne at DOP 4, 8, 10, 12, 16, 20 and the machine's maximum, each captured as an actual plan by an
-- Extended Events session that lasts only for this part. The session collects each plan with its
-- per-operator timing, which can raise the CPU of the runs it watches: over two runs on CU10, the
-- per-thread CPU summed to between 5% below and 21% above what repro.sql measured at the same DOP.
-- The row counts are exact either way.

-- a session left by a run that stopped partway is this script's own, so it is dropped, not refused
if exists (select * from sys.server_event_sessions where name = N'ClrSpinReproThreads')
    drop event session ClrSpinReproThreads on server;
go

-- this connection's plans in this database only; a ring buffer target keeps them only while the
-- session runs, so they are read before it stops
declare @ddl nvarchar(max) = N'create event session ClrSpinReproThreads on server
add event sqlserver.query_post_execution_showplan (
    where sqlserver.database_name = N''ClrSpinRepro''
        and sqlserver.session_id = ' + convert(nvarchar(10), @@spid) + N')
add target package0.ring_buffer (set max_memory = 16384)
with (event_retention_mode = no_event_loss, max_dispatch_latency = 1 seconds)';
exec (@ddl);
alter event session ClrSpinReproThreads on server state = start;
go

declare @maxdop int = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE');
declare @dops table (Dop int not null primary key);
insert @dops select distinct d from (values (4), (8), (10), (12), (16), (20), (@maxdop)) v(d) where d <= @maxdop;

declare @dop int = (select min(Dop) from @dops), @run int, @sql nvarchar(max), @n int;
while @dop is not null begin
    -- run 1 compiles and warms; only run 2's plan is read
    set @run = 1;
    while @run <= 2 begin
        set @sql = N'select @n = count(*) from dbo.T where dbo.AddOne(ID) = 0'
            + N' option (maxdop ' + convert(nvarchar(4), @dop) + N', use hint (''ENABLE_PARALLEL_PLAN_PREFERENCE''))';
        exec sys.sp_executesql @sql, N'@n int output', @n = @n output;
        set @run += 1;
    end
    set @dop = (select min(Dop) from @dops where Dop > @dop);
end
go

-- longer than max_dispatch_latency, so every plan has reached the ring buffer
waitfor delay '00:00:03';

create table #plans (Dop int not null primary key, PlanXml xml not null);

declare @target xml = (
    select convert(xml, t.target_data)
    from sys.dm_xe_session_targets t
    join sys.dm_xe_sessions s on s.address = t.event_session_address
    where s.name = N'ClrSpinReproThreads' and t.target_name = N'ring_buffer'
);

-- a captured plan carries no statement text, and the sql_text action gives the whole batch around
-- sp_executesql, so the runs are told apart by their plans: the two that call AddOne at each DOP, of
-- which the later is run 2
with xmlnamespaces (N'http://schemas.microsoft.com/sqlserver/2004/07/showplan' as p),
E as (
    select
        Ts = e.x.value(N'@timestamp', N'datetimeoffset(7)'),
        PlanXml = e.x.query(N'data[@name="showplan_xml"]/value/p:ShowPlanXML')
    from @target.nodes(N'/RingBufferTarget/event[@name="query_post_execution_showplan"]') e(x)
    where e.x.exist(N'data[@name="showplan_xml"]/value/p:ShowPlanXML//p:UserDefinedFunction[@FunctionName="[ClrSpinRepro].[dbo].[AddOne]"]') = 1
),
R as (
    select
        Dop = PlanXml.value(N'(//p:QueryPlan/@DegreeOfParallelism)[1]', N'int'),
        PlanXml,
        Latest = row_number() over (partition by PlanXml.value(N'(//p:QueryPlan/@DegreeOfParallelism)[1]', N'int') order by Ts desc)
    from E
)
insert #plans
select Dop, PlanXml
from R
where Latest = 1;

-- what the session caught, so a shortfall shows whether the plans never arrived or were not matched
select
    TargetFound = case when @target is null then 0 else 1 end,
    EventCount = @target.value(N'(/RingBufferTarget/@eventCount)[1]', N'int'),
    TotalEventsProcessed = @target.value(N'(/RingBufferTarget/@totalEventsProcessed)[1]', N'int'),
    DroppedCount = @target.value(N'(/RingBufferTarget/@droppedCount)[1]', N'int'),
    Truncated = @target.value(N'(/RingBufferTarget/@truncated)[1]', N'int'),
    MemoryUsed = @target.value(N'(/RingBufferTarget/@memoryUsed)[1]', N'int');

with xmlnamespaces (N'http://schemas.microsoft.com/sqlserver/2004/07/showplan' as p)
select
    EventName = e.x.value(N'@name', N'nvarchar(100)'),
    Ts = e.x.value(N'@timestamp', N'datetimeoffset(7)'),
    Dop = e.x.value(N'(data[@name="dop"]/value)[1]', N'int'),
    PlanDop = e.x.value(N'(data[@name="showplan_xml"]/value/p:ShowPlanXML//p:QueryPlan/@DegreeOfParallelism)[1]', N'int'),
    CallsAddOne = e.x.exist(N'data[@name="showplan_xml"]/value/p:ShowPlanXML//p:UserDefinedFunction[@FunctionName="[ClrSpinRepro].[dbo].[AddOne]"]')
from @target.nodes(N'/RingBufferTarget/event') e(x);

alter event session ClrSpinReproThreads on server state = stop;
drop event session ClrSpinReproThreads on server;

declare @maxdop int = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE');
-- a run whose DOP was lowered below the one asked shares its DOP with another and drops out here
if (select count(*) from #plans) < (select count(distinct d) from (values (4), (8), (10), (12), (16), (20), (@maxdop)) v(d) where d <= @maxdop)
    raiserror('the session caught fewer plans than runs; the grids below are incomplete', 16, 1);

-- every operator's counters on every thread; thread 0 is the coordinator
with xmlnamespaces (N'http://schemas.microsoft.com/sqlserver/2004/07/showplan' as p)
select
    Dop = pl.Dop,
    NodeId = r.x.value(N'@NodeId', N'int'),
    PhysicalOp = r.x.value(N'@PhysicalOp', N'nvarchar(60)'),
    Thread = c.x.value(N'@Thread', N'int'),
    ActualRows = c.x.value(N'@ActualRows', N'bigint'),
    CpuMs = c.x.value(N'@ActualCPUms', N'bigint'),
    ElapsedMs = c.x.value(N'@ActualElapsedms', N'bigint')
into #threads
from #plans pl
cross apply pl.PlanXml.nodes(N'//p:RelOp') r(x)
cross apply r.x.nodes(N'p:RunTimeInformation/p:RunTimeCountersPerThread') c(x);

-- each operator's spread across its worker threads
select
    Dop,
    NodeId,
    PhysicalOp,
    Threads = count(*),
    MinRows = min(ActualRows),
    MaxRows = max(ActualRows),
    TotalRows = sum(ActualRows),
    MinCpuMs = min(CpuMs),
    MaxCpuMs = max(CpuMs),
    TotalCpuMs = sum(CpuMs)
from #threads
where Thread > 0
group by Dop, NodeId, PhysicalOp
order by Dop, NodeId;

select * from #threads order by Dop, NodeId, Thread;
go
