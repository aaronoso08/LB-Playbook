-- Latino Built Bid Board: update 4 (remember when a job alert was sent). Safe to run again.
-- Run AFTER bid_board_update_3.sql.
alter table public.bid_job_private add column if not exists alerted_at timestamptz;
