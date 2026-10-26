# Latino Built Team Playbook

Staff-only hub for Latino Built. The page is encrypted (AES-256), so this repo only holds scrambled content.

- **Staff sign in** with their work email and password (Supabase). Only people on the staff list can unlock the page.
- `bids/` is the public contractor bid page. It only shows open jobs (city and scope, never client details).
- `bids/*.sql` are the database setup files, in order: `bid_board_setup.sql`, `bid_board_update_1.sql`, `team_update_3.sql`, `bid_board_update_2.sql`, `bid_board_update_3.sql`. (`team_update_2.sql` is old and stops itself if run.)
- Staff list: the bid board and the Playbook share one list (`team_member`). Turning someone off there removes both. `bid_staff` is just an automatic copy.
- Job alerts: contractors sign up on the bid page (text and/or email, trades, areas, language) and get a private link to change or stop. Only staff can see the list.
- Jobs past their bid deadline close on their own (the bid page and the daily keep-awake job both tidy them up).
- The staff list and page key are set up from a private file that is never stored here.
