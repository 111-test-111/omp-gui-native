# Shared real library

Tivano and Tivano Dev use the same library, thread JSON, attachments, MCP store,
wallpaper, worktrees and patches:

- `~/Library/Application Support/Tivano`
- `~/.tivano`
- Keychain service `Tivano` (provider API keys and MCP secrets)

Bundle IDs, app names, preferences and macOS privacy grants remain distinct.
The first Dev launch can seed missing preferences from Release/the upstream
bundle domain; later preference changes are independent. CLI logins remain in
those providers' own locations.

This is an intentionally shared live store, **not a mirror**. `sync_dev_data.sh`
is now a no-op compatibility entry point; the old `rsync --delete` behavior and
`TIVANO_DEV_SYNC` have been retired. Changing/deleting a session or credential in
one edition affects the other. The owner has accepted that risk.

## One writer

Before loading settings/library, the app holds an advisory file lease at
`~/Library/Application Support/.tivano-library.lock` until process exit. A second
edition stops with an explanation rather than loading a stale in-memory copy
and overwriting whole JSON files. Normal OS process exit releases the lease;
a leftover lock file is harmless and should not be deleted to bypass the guard.

Capture runs retain their isolated store and do not claim the real-library lease.
The older Droppy/Cody app does not know this lock, so startup also refuses while
that older bundle is running. Quit it explicitly before switching to Tivano.
Packaging/installing the new apps does not quit or modify the running older app.

## First-launch migration

Both editions run the same migration after acquiring the lease. If no Tivano
store exists, the real upstream `Droppy Code` store is preferred over Cody or an
old isolated `Tivano Dev` store:

1. Copy a backup into `~/Library/Application Support/Tivano Backups/migration-<id>/`.
2. Move the store to `Tivano`.
3. Leave the former store path as an alias to the new store, preserving saved
   absolute attachment paths. If alias creation fails, move the store back.
4. Alias `~/.tivano` to the former `~/.droppy-code` when it exists: moving registered
   git worktrees would break their absolute-path registrations.
5. Seed missing per-edition preferences but omit upstream cached update downloads.
   Only mark success after all steps complete, so errors can be retried.

If a Tivano store already exists, it is never overwritten or merged automatically.
Any other isolated legacy store remains untouched for owner review. Credentials
can be carried into the shared service on access without exporting them to files;
macOS may ask for authorization once. Forgetting a shared credential also removes
its matching legacy copies, preventing silent re-import.

The library file format still belongs to the running app version. A writer lock
protects against concurrent saves, not against an incompatible Dev schema or
old Release discarding fields it does not understand. Take an offline backup
before such tests. Don't launch the old Droppy app after migration: it can still
write through its compatibility alias without honoring the new lock.
