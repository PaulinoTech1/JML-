# App Registration: Least-Privilege Permissions

Each script needs only the permissions for its own job. Register one app per script (or one app with the union, if you prefer fewer registrations), and grant **application** permissions for automation or **delegated** permissions for interactive testing.

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
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | **Only if** using `-IncludeDevices` for mobile wipe |

## Access review (`Review-AccessReview.ps1`, read-only)

| Permission | Why |
|---|---|
| `User.Read.All` | Enumerate users and sign-in activity |
| `Directory.Read.All` | Read directory objects |
| `RoleManagement.Read.Directory` | Read privileged role assignments |
| `AuditLog.Read.All` | Read `signInActivity` timestamps |

## Registration checklist

1. Microsoft Entra admin center > Identity > Applications > App registrations > New registration.
2. No redirect URI needed for app-only (client credentials) flow.
3. API permissions > Add > Microsoft Graph > **Application** permissions > add the rows above.
4. Grant admin consent.
5. Certificates & secrets: prefer a **certificate** over a client secret. Upload the public cert, keep the private key in the machine store of the automation host.
6. If you must use a secret: store it in the automation host's secret store and expose it only as `LIFECYCLE_CLIENT_SECRET` at runtime. It must never appear in this repo, in logs, or in chat.
7. Conditional Access: consider a policy that restricts this app to your automation host's network location.
