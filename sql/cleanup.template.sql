-- Removes what the repro scripts create, for a run that stopped partway: database ClrSpinRepro, every
-- assembly trust they added, and threads.sql's event session. The last result set shows what is left,
-- both 0 when done.
if exists (select * from sys.server_event_sessions where name = N'ClrSpinReproThreads')
    drop event session ClrSpinReproThreads on server;
go
