# Setup

7. Done 2026-10-05: `supabase/migrations/0006_checkin_method.sql` adds how a check-in was made; run it after `0005`, then change "Not yet run" to "Done <date>". It is safe to run again.
   7a. Done 2026-10-05: `supabase/migrations/0007_schedule_versions.sql` (same command). Run it after `0006`, then change "Not yet run" to "Done <date>".
   7b. Not yet run: `supabase/migrations/0024_station_chimes_off.sql` (same command) adds the chimes switch; run it before the web build that reads it is deployed.
