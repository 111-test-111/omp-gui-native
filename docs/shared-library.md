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

## Concurrent editions

Compatible Tivano and Tivano Dev builds can run together. Both hold a shared
startup lease at `~/Library/Application Support/.tivano-library.lock`; an older
build that requires an exclusive lease still blocks them. Update both editions
before using this feature.

Different conversations can be edited concurrently. A conversation and its
helper threads share one exclusive editing lease. The other edition displays
that conversation read-only and refreshes saved changes. Use **Release editing**
in the owning edition, or switch to another conversation after finishing work
and clearing drafts/terminals, then **Edit here** in the other edition.

Library and MCP metadata use short locked read/merge/write transactions.
Independent edits are merged, unknown fields retained, and conflicting edits
are refused rather than overwriting another edition's data. Thread heads and
turn files are read and written under a separate short document lock. MCP
provider launch configs and token accounting caches are isolated by process or
edition. Automatic orphan-attachment and abandoned-Hydra-copy cleanup is paused
because another edition may still use those files.

Normal OS process exit releases leases. Never delete lock files to bypass them.
Capture runs retain their isolated store. Startup still refuses while an older
Droppy/Cody app is running. Packaging never quits an app.

## First-launch migration

Both editions run the same migration under a separate exclusive migration lease. If no Tivano
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

The library file format still belongs to the running app version. Editing leases and JSON transactions
protect concurrent saves; they do not make incompatible schemas interchangeable. Take an offline backup
before such tests. Don't launch the old Droppy app after migration: it can still
write through its compatibility alias without honoring the new lock.
