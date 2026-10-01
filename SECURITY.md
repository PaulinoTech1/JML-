# Security Policy

## Threat model

These scripts hold credentials that can create, modify, and destroy identity objects in a Microsoft Entra tenant. The relevant threats:

| Threat | Mitigation in this repo |
|---|---|
| Script run against the wrong tenant | Tenant ID is explicit config; dry-run default forces a review pass before any `-Apply` |
| Credential leak via repo or logs | Secrets only from env vars / cert store; temp password never logged or printed; `logs/` and `reports/` are gitignored |
| Client secret theft on a shared host | Certificate auth is the documented default; a warning fires on secret auth; never set the secret via interactive `export` (shell history) |
| App registration granted broader scopes than needed | One app per script is the documented default (blast-radius reduction); verify grants against `docs/APP_REGISTRATION.md`; residual: Graph's coarse `User.ReadWrite.All` means any mutating app is high-value. Protect these credentials like the tenant depends on it: certificate-first auth, short-lived secrets, Conditional Access on the service principal |
| Accidental mass offboarding | Leaver requires typed confirmation; `-Force` requires `-ChangeTicket` and fails closed without it; the ticket is audit-logged. The ticket gate is a presence/format check only: it does not verify approval in an ITSM and cannot stop an invented ticket ID. Approval is process control; the code gives you the audit trail to enforce it. Optional `changeTicketPattern` in the config enforces a ticket format. |
| Mover strips legitimate access | Removals limited to the managed universe; manual assignments are never touched |
| Group renamed or duplicate display name redirects a membership change | Groups are resolved by immutable object ID; config names are labels only; drift produces a warning |
| Tenant larger than the tool's design | Access review fails closed above `maxTenantUsers` (default 1,000) instead of returning incomplete results |
| Privilege creep in the app registration | Per-script least-privilege permission tables in `docs/APP_REGISTRATION.md` |
| Silent failures (script says done, tenant disagrees) | Every step audits `Executed`/`Failed` with the Graph error message; the run prints a failed-step summary at the end and writes a `Run.PartialFailure` audit record. Steps are sequential with no automatic rollback (rolling back a half-finished offboarding could re-enable an account that must stay disabled); reconcile from the JSONL per docs/RUNBOOK.md. In `-Apply` mode each script also re-queries and audits a `Verify.*` state check, warning on mismatch. |

## What these scripts deliberately do NOT do

- Store credentials, tokens, or passwords anywhere in the repo.
- Send data anywhere except Microsoft Graph and the local audit log.
- Handle mailboxes (Exchange Online is a separate permission boundary; the runbook covers the manual step).
- Wipe devices by default. Remote wipe is available only as an explicit, separately gated opt-in (`-IncludeDevices` on the leaver, which always requires `-ChangeTicket` and its own Intune permission); it is never part of the default offboarding flow.
- Auto-approve anything. The human confirms the plan.

## Reporting a vulnerability

Open a GitHub issue. Do not include tenant data, credentials, or audit logs in the report.
