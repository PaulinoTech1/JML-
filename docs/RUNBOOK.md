# Operational Runbook

How to run identity lifecycle automation in production. Written for the admin who inherits this, not the admin who wrote it.

## One-time setup

1. Complete `docs/APP_REGISTRATION.md`. Prefer certificate auth.
2. Copy and fill in the configs:
   - `config/lifecycle-config.json` (from `.example`)
   - `config/role-mappings.json` (from `.example`)
3. Validate SKU part numbers: `Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId`.
4. Run every script once with `-Interactive` and **without** `-Apply` against a test user. Read the audit log. Confirm the plan matches your intent.

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
2. Dry run first. Verify the group list being removed looks complete.
3. Live run: `./src/Leaver-OffboardEmployee.ps1 -UserPrincipalName '...' -Apply`, then type the confirmation phrase.
4. **Mailbox (manual, Exchange Online):** convert to a shared mailbox or set forwarding, then remove the license (the script already removed licenses; re-add briefly if the shared mailbox exceeds 50 GB per Microsoft's rules, then remove again after conversion):
   ```powershell
   Set-Mailbox 'user@domain' -Type Shared
   ```
5. Wipe mobile devices only with explicit approval: `-IncludeDevices`.
6. File the audit log path in the termination ticket.

## Quarterly access review

1. Run `./src/Review-AccessReview.ps1` (read-only, safe on a schedule).
2. Work the four CSVs in `reports/`:
   - `stale-accounts-*.csv`: disable or investigate anything past your stale threshold.
   - `privileged-roles-*.csv`: confirm every assignment is still justified. Challenge Global Admin count first.
   - `guest-users-*.csv`: remove guests whose engagement ended.
   - `license-waste-*.csv`: reclaim licenses from disabled accounts.
3. Keep the reports with your compliance evidence.

## Rollback notes

- **Joiner/mover mistakes** are reversible: re-run the mover with the correct department, or manually re-add groups. Licenses can be reassigned.
- **Leaver mistakes** are partially reversible: a disabled account can be re-enabled within the retention window, group memberships must be re-added manually (the audit log lists exactly what was removed), licenses must be reassigned. **There is no undo button for device wipes.** That switch exists for a reason and requires explicit opt-in.
- The audit log is the source of truth for what changed. Keep it.
