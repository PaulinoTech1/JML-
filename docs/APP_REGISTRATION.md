# App Registration: Least-Privilege Permissions

Each script needs only the permissions for its own job. **Register one app per script.** Separate registrations bound the blast radius: the read-only review app can never mutate anything, and a compromised joiner credential does not carry the leaver's permissions.

A single app with the union of all permissions is supported but **not recommended**: one credential would then hold full user/group/license control of the tenant, and a compromise anywhere is a compromise everywhere. For a small business, separate registrations are free and take minutes each. There is no good reason to use the union.

Grant **application** permissions for automation or **delegated** permissions for interactive testing. In interactive mode each script requests only its own scopes (see the `$*Scopes` variables in `src/`).

> Verify these against the [Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference) before granting. Permission requirements evolve; this table was written against the v1.0 endpoint in 2026.

## Joiner (`Joiner-NewEmployee.ps1`)

| Permission | Why |
|---|---|
| `User.ReadWrite.All` | Create user, assign licenses, set manager |
| `GroupMember.ReadWrite.All` | Add user to role groups |
| `Directory.Read.All` | Resolve manager UPN, read group display names |
| `Organization.Read.All` | Read subscribed SKUs to map part numbers to SkuIds |

## Mover (`Mover-UpdateEmployee.ps1`)

| Permission | Why |
|---|---|
| `User.ReadWrite.All` | Update attributes, assign/remove licenses |
| `GroupMember.ReadWrite.All` | Add/remove role group memberships |
| `Directory.Read.All` | Read current memberships, resolve names |
| `Organization.Read.All` | Read subscribed SKUs |

## Leaver (`Leaver-OffboardEmployee.ps1`)

| Permission | Why |
|---|---|
| `User.ReadWrite.All` | Revoke sessions, disable account, remove licenses, stamp leave date |
| `GroupMember.ReadWrite.All` | Remove direct group memberships |
| `Directory.Read.All` | Enumerate memberships |

> **Device wipe (optional):** `-IncludeDevices` on the leaver wipes the user's Intune-enrolled devices. It additionally requires `DeviceManagementManagedDevices.PrivilegedOperations.All` (delegated; app-only equivalent from your Intune permission set) and **always requires `-ChangeTicket`**, in every mode. Only grant this permission on the app registration used for offboarding if your process calls for scripted wipes (e.g. lost/stolen devices); otherwise leave it off and the wipe code path can never execute.

## Access review (`Review-AccessReview.ps1`, read-only)

| Permission | Why |
|---|---|
| `User.Read.All` | Enumerate users and sign-in activity |
| `Directory.Read.All` | Read directory objects |
| `RoleManagement.Read.Directory` | Read privileged role assignments |
| `AuditLog.Read.All` | Read `signInActivity` timestamps |

## Registration checklist

1. Microsoft Entra admin center > Identity > Applications > App registrations > New registration. **One registration per script** (joiner, mover, leaver, access review).
2. No redirect URI needed for app-only (client credentials) flow.
3. API permissions > Add > Microsoft Graph > **Application** permissions > add only the rows for that script's table above.
4. Grant admin consent.
5. **Verify your grants.** After consenting, open the app's API permissions blade and confirm the granted list matches the table, nothing more. Re-verify after any permission change. The scripts cannot enforce what the app registration grants; this check is on you.
6. Certificates & secrets: prefer a **certificate** over a client secret. Upload the public cert, keep the private key in the machine store of the automation host.
7. If you must use a secret: store it in the automation host's secret store (Task Scheduler credential, Azure Automation variable, etc.) and expose it only as `LIFECYCLE_CLIENT_SECRET` at runtime. **Never** set it with an interactive `export` or `$env:` assignment: it lands in shell history and stays in process memory. It must never appear in this repo, in logs, or in chat. Expect a warning on every run until you switch to a certificate.
8. Conditional Access: consider a policy that restricts this app to your automation host's network location.

> Residual risk, stated plainly: Microsoft Graph's user permissions are coarse. `User.ReadWrite.All` lets an app create users *and* disable them, so even per-script registrations leave each mutating app high-value. Separate apps bound the blast radius; they do not eliminate it. Protect these credentials like the tenant depends on it, because it does.
