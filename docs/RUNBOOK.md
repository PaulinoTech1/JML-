# Operational Runbook

How to run identity lifecycle automation in production. Written for the admin who inherits this, not the admin who wrote it.

## One-time setup

1. Complete `docs/APP_REGISTRATION.md`. Prefer certificate auth. Register one app per script.
2. Copy and fill in the configs:
   - `config/lifecycle-config.json` (from `.example`)
   - `config/role-mappings.json` (from `.example`)
3. Validate SKU part numbers: `Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId`.
4. Look up group object IDs for the role mappings: `Get-MgGroup | Select-Object Id, DisplayName`. Groups are referenced by immutable ID, never display name.
5. Run every script once with `-Interactive` and **without** `-Apply` against a test user. Read the audit log. Confirm the plan matches your intent.
6. Note the tenant-size boundary: this tool is sized for tenants up to `maxTenantUsers` (default 1,000). The access review fails closed above it.
7. Set a real, nonzero `tenantId` in lifecycle config. If `LIFECYCLE_TENANT_ID` is present, it must agree. Each entry point verifies the authenticated Graph tenant. Use a separate PowerShell process for each lifecycle run.
8. Role mappings must contain explicit `groups` and `licenses` arrays. Use `[]` only when empty access is intended; omitted/null fields are rejected. See [the security corrections and their rationale](SECURITY_FIXES.md).

## Joiner (new hire)

1. HR provides: legal first/last name, department, job title, manager, start date.
2. Dry run:
   ```powershell
   ./src/Joiner-NewEmployee.ps1 -FirstName ... -LastName ... -Department ... -Apply:$false
   ```
   (Dry run is the default; the explicit flag is for readability in tickets.)
3. Review `logs/lifecycle-*.jsonl` for the run.
4. Live run with `-Apply`. The temporary password is generated but **never printed or logged**. Hand it to HR through your secure channel (password manager share, sealed envelope, etc.).
5. If the start date is in the future, the account is created **disabled**. On the start date, enable it:
   ```powershell
   Update-MgUser -UserId 'user@domain' -AccountEnabled:$true
   ```
   and log that action in the ticket.

## Mover (department / role change)

1. Dry run first, review the add/remove plan. Pay attention to the `Remove` list: it only contains groups inside the managed universe, but confirm nothing business-critical is being stripped.
2. Live run with `-Apply`.
3. If the user needs access the role mapping does not cover (project groups, exceptions), assign those **manually**. The mover will never remove them because they are outside the managed universe.

## Leaver (termination)

1. Confirm the termination with HR in the ticket. This script is destructive by design.
2. Dry run first. Verify the group list being removed looks complete. Note: unlike the mover, the leaver removes **all** direct group memberships, not just the ones in the managed universe. Anything the person needs afterwards must be re-added manually from the audit log.
3. Live run: `./src/Leaver-OffboardEmployee.ps1 -UserPrincipalName '...' -Apply`, then type the confirmation phrase.
4. **Scheduled/unattended runs:** `-Force` skips the typed confirmation but **requires** `-ChangeTicket` with the approved change record reference (e.g. `-Force -ChangeTicket 'CHG-1234'`). The ticket is written to the audit log. `-Force` without a ticket fails closed. Honest scope: the gate checks the ticket is present (and matches `changeTicketPattern` if you configured one); it does not call your ITSM, check a signature, or stop an invented ticket ID. Ticket approval is your change process's job; the code's job is making the reference undeniable in the audit trail.
5. **Mailbox (manual, Exchange Online):** convert to a shared mailbox or set forwarding, then remove the license (the script already removed licenses; re-add briefly if the shared mailbox exceeds 50 GB per Microsoft's rules, then remove again after conversion):
   ```powershell
   Set-Mailbox 'user@domain' -Type Shared
   ```
6. **Mobile devices (optional, gated):** by default the scripts never wipe devices. If your process calls for it (e.g. lost or stolen devices), add `-IncludeDevices` to the leaver run: it wipes the user's Intune-enrolled devices, but it **requires `-ChangeTicket`** with the approved change record reference in every mode, including interactive runs, and the authorization is written to the audit log. A wipe issued against the wrong account is unrecoverable, so never add the flag by habit; confirm the UPN and the ticket first. The app registration also needs the `DeviceManagementManagedDevices.PrivilegedOperations.All` permission (see `docs/APP_REGISTRATION.md`) or the wipe step fails closed.
7. File the audit log path in the termination ticket.
8. Live mover and leaver runs for the same tenant/user are mutually exclusive on the same host. A conflicting run stops instead of waiting or retrying. After the active run completes, review its audit and tenant state before retrying. This does not coordinate separate hosts or external Graph clients, and a later mover can still regrant access. Do not automatically retry device wipes.

## Quarterly access review

1. Run `./src/Review-AccessReview.ps1` (read-only, safe on a schedule).
2. Work the four CSVs in `reports/`:
   - `stale-accounts-*.csv`: disable or investigate anything past your stale threshold.
   - `privileged-roles-*.csv`: confirm every assignment is still justified. Challenge Global Admin count first.
   - `guest-users-*.csv`: remove guests whose engagement ended.
   - `license-waste-*.csv`: reclaim licenses from disabled accounts.
3. Keep the reports with your compliance evidence.

## Recovering from a partial failure

Steps run sequentially, and there is no automatic rollback: a failed group add does not undo the account creation that preceded it, and rolling back a half-finished offboarding could re-enable an account that must stay disabled. A terminating error may stop the script before its final failed-step summary or `Run.PartialFailure` record; inspect the per-step audit even if no `Done` message appears. Reconcile like this:

1. Open the run's JSONL audit log (the path is printed at the end of the run).
2. Find every entry with `"result":"Failed"`; each carries the Graph error message in `detail`.
3. Fix the underlying cause (missing group ID in config, exhausted license SKU, throttled Graph call, typo in the ticket).
4. Re-run the script. The joiner and mover are idempotent for completed steps (existing UPNs are skipped, converged access produces an empty plan), so re-running only completes what is left. For the leaver, confirm in a dry run that the remaining steps are the ones you expect before applying.
5. In `-Apply` mode each script also performs a post-apply state check (re-queries the tenant and audits a `Verify.*` record). A `Verify.*` failure is a warning, not a throw: Graph eventual consistency can lag, so treat it as "look at this" rather than "broken". If the state still disagrees after a few minutes, go back to step 2.

## Rollback notes

- **Joiner/mover mistakes** are reversible: re-run the mover with the correct department, or manually re-add groups. Licenses can be reassigned.
- **Leaver mistakes** are partially reversible: a disabled account can be re-enabled within the retention window, group memberships must be re-added manually (the audit log lists exactly what was removed; remember the leaver removes **all** direct memberships, not just managed-universe ones), licenses must be reassigned.
- The audit log is the source of truth for what changed. Keep it.
