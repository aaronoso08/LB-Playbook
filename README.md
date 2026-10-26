# Latino Built Team Playbook

Staff-only hub for Latino Built. The page is encrypted (AES-256), so this repo only holds scrambled content.

- **Staff sign in** with their work email and password (Supabase). Only people on the staff list can unlock the page.
- `bids/` is the public contractor bid page. It only shows open jobs (city and scope, never client details).
- `bids/*.sql` are the database setup files, in order: `bid_board_setup.sql`, `bid_board_update_1.sql`, `team_update_3.sql`, `bid_board_update_2.sql`, `bid_board_update_3.sql`, `bid_board_update_4.sql`, `team_update_4.sql` (team to-do board), `team_update_5.sql` (meeting notes, monthly report). (`team_update_2.sql` is old and stops itself if run.)
- Staff list: the bid board and the Playbook share one list (`team_member`). Turning someone off there removes both. `bid_staff` is just an automatic copy.
- Job alerts: contractors sign up on the bid page (text and/or email, trades, areas, language) and get a private link to change or stop. Only staff can see the list.
- Jobs past their bid deadline close on their own (the bid page and the daily keep-awake job both tidy them up).
- The page key lives only in Supabase (`team_vault`). Admins can see it with `select page_key from team_vault;`.
- `tools/playbook.py` opens (unscrambles) the page for editing and seals it again. No secrets are stored in it. Never commit the unscrambled `playbook_source.html`.
- `docs/` holds program documents (PDFs, the funding matrix, contracts), scrambled with the same page key. They only open inside the Playbook for signed-in staff. Add one with `python3 tools/playbook.py doc`, then list it in DOCS in the page.
- There is no shared team password anymore. Everyone signs in with their own work email.

## When someone leaves the team
1. In Supabase SQL Editor: `update team_member set active = false where email = 'their.email@latinobuilt.org';` (this also removes them from the bid board).
2. Change the page key: open the page with the current key, then `python3 tools/playbook.py seal --new-key --key "<current key>"` (this also re-scrambles everything in `docs/`), push, wait about 2 minutes for the site to update.
3. Paste the SQL line it prints into Supabase and Run. Everyone else signs in again once; the old key stops working.
