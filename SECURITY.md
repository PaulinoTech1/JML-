# Security Policy

## Threat model

These scripts hold credentials that can create, modify, and destroy identity objects in a Microsoft Entra tenant. The relevant threats:

| Threat | Mitigation in this repo |
|---|---|
| Script run against the wrong tenant | Tenant ID is explicit config; dry-run default forces a review pass before any `-Apply` |
| Credential leak via repo or logs | Secrets only from env vars / cert store; temp password never logged or printed; `logs/` and `reports/` are gitignored |
| Accidental mass offboarding | Leaver requires typed confirmation; `-Force` is for scheduled runs with change records, not interactive use |
| Mover strips legitimate access | Removals limited to the managed universe; manual assignments are never touched |
| Privilege creep in the app registration | Per-script least-privilege permission tables in `docs/APP_REGISTRATION.md` |
| Silent failures (script says done, tenant disagrees) | Every step audits `Executed`/`Failed` with the Graph error message; failures throw |

## What these scripts deliberately do NOT do

- Store credentials, tokens, or passwords anywhere in the repo.
- Send data anywhere except Microsoft Graph and the local audit log.
- Handle mailboxes (Exchange Online is a separate permission boundary; the runbook covers the manual step).
- Auto-approve anything. The human confirms the plan.

## Reporting a vulnerability

Open a GitHub issue. Do not include tenant data, credentials, or audit logs in the report.
