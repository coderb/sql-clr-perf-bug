-- SQLCLR scalar functions in a parallel plan: CPU per call grows far faster than the thread count,
-- with heavy spinning on SOS_SELIST_SIZED_SLOCK and SOS_CACHESTORE.
--
-- Run as sysadmin, on an otherwise idle server: the spinlock counters are server-wide. The script
-- creates database ClrSpinRepro, trusts its one assembly by hash for the length of the run, and removes
-- both at the end; it changes no server setting. Run cleanup.sql if it stops partway.
--
-- Each function does a few character or integer comparisons, so any cost beyond that is the cost of
-- calling it. The control runs the same scan with the check written in T-SQL.

set nocount on;
go

select
    Version = @@version,
    CpuCount = (select cpu_count from sys.dm_os_sys_info),
    VisibleOnlineSchedulers = (select count(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE'),
    MaxDop = (select value_in_use from sys.configurations where name = 'max degree of parallelism'),
    CostThreshold = (select value_in_use from sys.configurations where name = 'cost threshold for parallelism'),
    ClrEnabled = (select value_in_use from sys.configurations where name = 'clr enabled'),
    ClrStrictSecurity = (select value_in_use from sys.configurations where name = 'clr strict security');
go

-- SSMS runs every batch even after one fails, so a failed check turns on noexec, which compiles the rest
-- of the script and runs none of it; reconnect afterwards, or run set noexec off
if (select convert(int, value_in_use) from sys.configurations where name = 'clr enabled') = 0 begin
    raiserror('clr enabled is 0; this script does not change server settings. Stopping.', 16, 1);
    set noexec on;
end
go

if db_id(N'ClrSpinRepro') is not null begin
    raiserror('database ClrSpinRepro already exists; run cleanup.sql first. Stopping.', 16, 1);
    set noexec on;
end
go

create database ClrSpinRepro;
go
use ClrSpinRepro;
go
if db_name() != N'ClrSpinRepro' begin
    raiserror('not in database ClrSpinRepro; stopping before anything is created', 16, 1);
    set noexec on;
end
go

declare @hash varbinary(64) = {{ASSEMBLY_SHA512}};
if not exists (select * from sys.trusted_assemblies where hash = @hash)
    exec sys.sp_add_trusted_assembly @hash = @hash, @description = N'ClrSpinRepro';
go

create assembly ClrSpin from {{ASSEMBLY_HEX}} with permission_set = safe;
go

-- the same method, declared with max and with sized parameters
create function dbo.IsMarkedMax(@group nvarchar(max), @code nvarchar(max)) returns bit
as external name ClrSpin.[ClrSpin.Functions].IsMarked;
go
create function dbo.IsMarked4000(@group nvarchar(4000), @code nvarchar(4000)) returns bit
as external name ClrSpin.[ClrSpin.Functions].IsMarked;
go
create function dbo.IsMarkedSql(@group nvarchar(4000), @code nvarchar(4000)) returns bit
as external name ClrSpin.[ClrSpin.Functions].IsMarkedSql;
go
create function dbo.AddOne(@x int) returns int
as external name ClrSpin.[ClrSpin.Functions].AddOne;
go

-- 2,000,000 rows, a heap; one row in 20 has 'M' as its code's fourth character
create table dbo.T (
    ID int not null,
    GroupName varchar(255) not null,
    Code varchar(255) not null
);

with N as (
    select top (2000000) n = row_number() over (order by (select null))
    from sys.all_columns a cross join sys.all_columns b cross join sys.all_columns c
)
insert dbo.T with (tablock)
select
    n,
    'G' + right('0' + convert(varchar(2), n % 67), 2),
    stuff(right('000000000000' + convert(varchar(12), n), 12), 4, 1, case when n % 20 = 0 then 'M' else 'X' end)
from N;
go

