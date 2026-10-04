# Mutation gate and leaver corrections

These changes follow the October 4, 2026 independent AI source review. They address four operating risks, with regression tests that exercise the actual workflows using fake Graph modules. They do not represent a live-tenant penetration test or certification.

## 1. Bind execution to the configured tenant

**Why:** The config contained `tenantId`, but entry points authenticated using `LIFECYCLE_TENANT_ID` instead. Valid credentials and a resolvable target in another tenant could turn an otherwise approved run into a wrong-tenant change.

**Change:** `Get-LifecycleConfig` requires a nonzero tenant GUID. Every entry point loads config before authenticating and passes that tenant explicitly. `Connect-LifecycleGraph` rejects a conflicting or malformed tenant environment, connects with process-scoped context, and checks the actual Graph context tenant before returning successfully. The leaver also displays the configured tenant before typed confirmation.

**Migration:** Populate `tenantId` with your actual tenant GUID; the all-zero example is a placeholder and is rejected. If `LIFECYCLE_TENANT_ID` is set, update it to agree or remove it. Client ID, certificate and secret channels are unchanged. Run one lifecycle script per PowerShell process: process-scoped Graph authentication is not isolation between simultaneous runspaces using the real SDK.

**Tests:** Missing/malformed/null/placeholder config tenants, environment disagreement, authenticated-context disagreement, GUID case normalization, and secret/certificate/interactive authentication. A workflow test asserts that context mismatch stops before user lookup or mutation.

## 2. Never interpret unknown account state as disabled

**Why:** The leaver did not explicitly request `accountEnabled`, then used its truthiness to decide whether to disable and whether verification passed. A null or missing property could skip disabling and falsely report success. Microsoft Graph requires `$select` for properties outside its default projection; see [Get user](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0).

**Change:** Initial, locked refresh and verification reads request `id,accountEnabled`. Only an explicit Boolean `false` permits skipping disable. True, null, omitted or unexpected values trigger the gated disable operation. Verification records `Failed` for unknown state; it never claims an unknown value proves sign-in is blocked. Session revocation still precedes account disabling, and dry-run never invokes either mutation.

**Tests:** True/null/false initial states, omitted properties, unknown verification state, and explicit property selection. Tests assert both the disable calls and audit outcomes.

## 3. Distinguish malformed role policy from intentionally empty access

**Why:** Missing or null `groups` and `licenses` became empty targets. A typo in a department mapping could therefore remove all currently managed access during a mover run.

**Change:** Department mappings must be objects with explicit `groups` and `licenses` arrays. `[]` remains a valid intentional empty target. Groups require nonempty labels and nonzero GUID IDs; licenses require nonempty SKU strings. The mover builds its target role and both managed removal universes from one validated snapshot, excluding underscore-prefixed metadata from access policy. This also closes the reviewer's finding that raw metadata license values could widen removals. Invalid mappings fail before Graph authentication or access mutations in joiner/mover workflows.

**Migration:** Replace omitted/null fields with explicit arrays only after confirming that empty access is intended. Scalar license strings become arrays, such as `"licenses": ["SPB"]`. Resolve actual group GUIDs; display names remain labels. This is validation of trusted policy, not a permission boundary against someone who can rewrite that policy.

**Tests:** Missing/misspelled/null/scalar fields, malformed group IDs, invalid license entries, invalid other departments, preserved empty roles, metadata exclusion, and snapshot consistency after a file changes. Existing tests continue to check preservation of manually assigned access outside the managed universe.

## 4. Handle empty results and overlapping offboarding safely

**Why:** PowerShell pipelines return no object for an empty license query. Accessing `.Count` under strict mode could stop offboarding after earlier changes. Two live runs for the same user could also issue duplicate operations or race a mover that grants access.

**Change:** The leaver wraps license output in `@(...)`, making zero/one/many results consistent. Live leaver and mover runs acquire the same named mutex keyed by canonical tenant GUID and immutable user GUID before state-dependent reads or mutations. They refresh the user after acquisition and hold ownership through verification. Contention, lock-access errors and detected abandonment stop the run. Nested `finally` releases ownership even if disconnect fails. Dry runs do not acquire mutation ownership.

**Tests:** Zero/one/multiple license results complete leave-date stamping; synchronized overlapping leaver/leaver and leaver/mover tests assert that the second run cannot mutate. A failed mutation releases ownership for a reconciled retry. Separate-process tests check same-key exclusion, other-user/tenant independence, case normalization, and release. An abandoned-owner test checks fail-closed handling.

**Limits and recovery:** This is cooperative exclusion on one host, using the Windows global named-object namespace across sessions and a named mutex on other platforms. OS permissions can deny acquisition, which stops the run. It does not coordinate different hosts, external Graph clients, or malicious code with existing credentials. It does not make the workflow transactional or prevent a later authorized mover from granting access after offboarding. Central scheduling and lifecycle policy must address those cases. Crash detection is conditional: abandonment can only be reported while the named object survives; a lock is not a durable completion record. After an interrupted or rejected run, inspect the audit and actual tenant state before deciding whether to retry. Do not automatically roll back a disabled account or retry device wipes.

## Validation and remaining boundaries

Local validation on Windows uses portable PowerShell 7.4.20, the CI-pinned Pester 5.2.2, and PSScriptAnalyzer 1.25.0: **111 tests passed, 0 failed, 0 skipped**, with source/test syntax checks, module import, and clean source analysis. Tests are offline; they do not verify deployed Graph permissions, eventual consistency, real SDK concurrency, device wipe completion, or distributed scheduling. Linux remains subject to the existing hosted CI job; this Windows run is not a cross-platform claim. Re-run after changes rather than treating this dated count as evidence for a later checkout.

To reproduce using those modules in PowerShell 7:

```powershell
Import-Module Pester -RequiredVersion 5.2.2
$result = Invoke-Pester -Path ./tests -PassThru
if ($result.FailedCount -gt 0 -or $result.FailedContainers.Count -gt 0 -or $result.NotRunCount -gt 0) { throw 'Pester validation failed' }
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
$issues = @(Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1)
if ($issues.Count -gt 0) { $issues; throw 'Source analysis failed' }
```

These changes preserve the explicit Apply gate, ticket-format/presence checks, optional wipe authorization and no-rollback policy. Tickets still do not prove ITSM approval. Authentication-mode auto-selection, broader UPN/domain schema validation, protected-account policy and durable tamper-resistant audit storage are separate work; this patch does not claim to implement them. A terminating step error may stop the run before its final summary, so reconcile the per-step audit even when no `Done` message appears.

The CI test command now also rejects failed test containers, unrun tests and zero-test discovery. Pester can report zero failed individual tests when discovery itself failed, so checking only `FailedCount` was insufficient evidence of a successful run.
