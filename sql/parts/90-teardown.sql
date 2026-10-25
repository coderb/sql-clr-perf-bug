
use master;
go
-- another connection still in the database, such as a second SSMS window or Object Explorer, would
-- stop the drop, so they are disconnected first
if db_id(N'ClrSpinRepro') is not null begin
    alter database ClrSpinRepro set single_user with rollback immediate;
    drop database ClrSpinRepro;
end
go
-- every trust this repro added, whichever build of the assembly it was for
declare @hash varbinary(64);
declare t cursor local fast_forward for
select hash from sys.trusted_assemblies where description = N'ClrSpinRepro';
open t;
fetch t into @hash;
while @@fetch_status = 0 begin
    exec sys.sp_drop_trusted_assembly @hash = @hash;
    fetch t into @hash;
end
close t;
deallocate t;
go
select
    ClrSpinReproLeft = case when db_id(N'ClrSpinRepro') is null then 0 else 1 end,
    TrustsLeft = (select count(*) from sys.trusted_assemblies where description = N'ClrSpinRepro');
go
