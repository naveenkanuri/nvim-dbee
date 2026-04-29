# Known Issues

## v1.3 Backlog

- `a and nil or b` Lua pattern cleanup:
  - `lua/dbee/handler/init.lua:780`
  - `lua/dbee/ui/drawer/init.lua:1904`
  These are pre-existing Lua truthiness bugs where the middle expression being falsy selects the wrong branch.

- Pre-existing legacy headless failures, verified on both `50b53eb` and `74bd66f`:
  - `check_actions_recovery.lua` — `ACTIONS_RECOVERY_FAIL=recover_execute_timeout`
  - `check_auto_reconnect.lua` — `CONN01_FAIL=deep_copy_retry_ok:false`
  - `check_notifications.lua` — `NOTIF_FAIL=notif04_add_node_not_found`
  - `check_drawer_yank.lua` — `CLIP02_FAIL=a10_connection_node_present`
  These are not Phase 11 regressions.
