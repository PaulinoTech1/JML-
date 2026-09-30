# Identity Lifecycle Security Platform Design

**Status:** Approved design checkpoint  
**Date:** 2026-09-30  
**Repository:** `PaulinoTech1/JML-`

## Purpose

Upgrade the existing PowerShell Joiner, Mover, Leaver, and Access Review automation into a portfolio-grade Identity Lifecycle Security Platform without replacing working lifecycle behavior or weakening its existing controls.

The platform follows one trust model:

> AI recommends. Policy authorizes. Humans approve. Deterministic automation executes.

Generative AI is advisory and is excluded from the trusted computing base for authorization. Microsoft Graph credentials remain available only to deterministic PowerShell code. Agent output is untrusted data and cannot become executable PowerShell, shell commands, Graph calls, approvals, or policy decisions.

## Existing Controls to Preserve

The implementation preserves these current properties:

- PowerShell remains the primary implementation language.
- Dry-run remains the default.
- Live mutation still requires explicit `-Apply`.
- Every Graph mutation passes through `Invoke-LifecycleStep`.
- Leaver retains typed confirmation unless a validated automation approval path applies.
- Mover removals remain limited to the managed entitlement universe.
- Configuration validation fails closed.
- Certificate authentication is preferred over client secrets.
- Secrets remain external to the repository and audit logs.
- Access Review remains read-only.

The implementation may change internal structure when needed to enforce policy, approvals, audit sanitization, Graph abstraction, and testability. Existing command-line entry points remain usable.

## Audit Findings Driving the Design

The current repository has six PowerShell files, two example configuration files, one Pester test file, and supporting documentation. All thirteen Microsoft Graph mutations in source currently execute inside `Invoke-LifecycleStep` script blocks.

The principal gaps are:

- The mutation gate checks dry-run state but has no policy decision, risk decision, protected-object check, approval artifact, or plan-integrity requirement.
- Leaver can modify protected identities and remove protected memberships.
- `-Force` bypasses typed confirmation without validating a structured approval.
- Certificate preference is documented but not reliably selected by the default authentication parameter set.
- Audit data has no central redaction and can record raw Graph exception text.
- Configuration accepts weakly validated structure and arbitrary properties.
- The example role mapping's `_comment` member can be interpreted as a department.
- Temporary passwords use modulo mapping over a 65-character alphabet; 65 does not evenly divide 256.
- The runbook shows a direct `Update-MgUser` command outside the mutation gate.
- Graph operations are coupled directly to lifecycle scripts.
- Tests do not cover Graph adapter behavior, authorization decisions, mutation-gate enforcement, AI boundaries, approval integrity, protected objects, SoD, drift, or audit redaction.
- There is no CI workflow, tenant-free full demo, architecture document, or detailed threat model.

## Architectural Approach

Use focused PowerShell modules and data files around the existing scripts. Avoid a service rewrite, microservices, runtime databases, and agent tool execution.

```text
Untrusted lifecycle input
        |
        v
Optional Intake Agent ------> structured advisory output only
        |
        v
Request Schema Validation
        |
        v
Deterministic Plan Builder <------ Optional Access Planning Agent
        |
        v
Deterministic Policy Engine
        |
        +------ DENY ----------> audit and stop
        |
        v
Optional Security Review Agent
        |
        v
Deterministic Risk Engine
        |
        v
Human Approval / explicit -Apply
        |
        v
Canonical Plan Hash Verification
        |
        v
Invoke-LifecycleStep
        |
        v
Graph Adapter
        |
        v
Microsoft Graph or Mock Graph
```

Policy and risk are calculated again from trusted configuration after agent output is accepted as data. An agent cannot supply authoritative values for approval, policy outcome, risk, plan hash, execution mode, object identifiers, or command names.

## Component Boundaries

### Request model and schema

Add a JSON Schema for four request types: `Joiner`, `Mover`, `Leaver`, and `AccessReview`. The schema rejects unknown properties and invalid enum values. Required fields vary by request type. Missing values remain missing and are never confused with inferred values.

Each request contains:

- `schemaVersion`
- UUID `requestId`
- `requestType`
- request-type-specific `subject`
- UTC `effectiveTime`
- `requestedEntitlements`
- `source`
- `requester`
- `approvalState`
- optional `inferences`, with field name, proposed value, confidence, and human-input requirement

Request IDs are generated as version 4 (random) UUIDs using `Guid.NewGuid()`. Examples and tests use synthetic identities under reserved example domains.

### Execution plan

The plan builder converts a validated request into a data-only execution plan. Each step uses a closed action enum such as `User.Create`, `GroupMember.Add`, `License.Assign`, or `User.Disable`. A plan contains no script blocks, PowerShell text, shell text, Graph URLs supplied by agents, or arbitrary command names.

Plan properties include request identity, subject identity, ordered actions, resolved entitlement identifiers, expected preconditions, policy version, schema version, risk classification, approval requirement, and dry-run state.

### Deterministic policy engine

The policy engine loads a strictly validated policy configuration with:

- department, role, group, and license mappings
- managed group and license boundaries
- protected groups, identities, service principals, and roles
- break-glass and emergency-access identities
- manager requirements
- approval requirements
- contractor and guest restrictions
- separation-of-duties rules
- forbidden automatic assignments
- unknown-entitlement behavior

Policy returns `Allow`, `Deny`, or `RequireEscalation` plus stable reason codes. A denial cannot be changed by an agent recommendation, natural-language approval claim, `-Force`, or plan metadata.

Unknown entitlements fail closed. Configured SoD rules evaluate the resulting entitlement set, including retained and newly requested managed access. Each conflict deterministically denies or requires escalation according to configuration.

### Deterministic risk engine

Risk classification is a pure function of request type, lifecycle transition, policy facts, target identity, and entitlements. It returns `Low`, `Medium`, `High`, or `Critical` with stable reason codes.

At minimum:

- Approved departmental Joiner access is Low.
- Department-changing Mover operations are Medium.
- Sensitive groups or applications are High.
- Privileged roles, break-glass targets, protected service principals, and policy-bypass attempts are Critical.

Agent explanations may describe this result but cannot set or lower it.

### Approval and plan integrity

Structured approvals contain:

- UUID `approvalId`
- UUID `requestId`
- approver identity
- UTC approval and expiry times
- SHA-256 `planHash`
- `ExecuteExactPlan` scope
- optional comments

The platform serializes plans using a canonical representation with fixed property ordering, invariant scalar formatting, ordered action arrays, and ordinal sorting for set-like arrays. It hashes the resulting UTF-8 bytes with SHA-256.

Immediately before live execution, deterministic code:

1. validates the approval schema;
2. checks request ID and approval scope;
3. checks UTC validity and expiry;
4. regenerates the canonical plan;
5. recalculates the hash;
6. compares hashes using ordinal comparison;
7. rejects any mismatch.

Hashing detects modification; it is not described as authentication or a digital signature. High and Critical plans require valid structured approval. Lower-risk live execution still requires explicit `-Apply`; configurable policy can require structured approval at any risk level.

### Central execution gate

`Invoke-LifecycleStep` remains the only mutation gate and gains a required execution context for live operations. The context includes request ID, action ID, policy decision, risk level, approval decision, verified plan hash, and adapter mode.

For live mutation the gate fails closed unless:

- the action appears in the validated plan;
- policy authorized the exact action and target;
- the target is not protected;
- required approval is valid;
- the current plan hash matches the approved hash;
- adapter mode is `Live`;
- the caller supplied `-Apply`.

Dry-run actions remain non-mutating and are audited as planned. Static tests verify that mutating Graph commands exist only inside the Graph adapter and are invoked only from the gate.

### Graph adapter

Move Graph reads and writes behind a small adapter with `Live` and `Mock` modes. The adapter exposes named lifecycle operations rather than arbitrary command execution.

The Live adapter contains the Microsoft Graph SDK calls. The Mock adapter stores synthetic directory state in memory or JSON fixtures and never imports Graph modules, contacts a tenant, or claims live execution.

The adapter does not accept PowerShell or shell text. It does not expose a generic command runner. Mutating adapter methods can only be called through `Invoke-LifecycleStep`.

### AI security gateway

AI is optional. Core request validation, planning, policy, risk, approvals, execution, audit, review, and demo behavior work without an AI key.

Provider contracts support:

- a fully implemented deterministic Mock provider for tests, CI, and demos;
- an optional OpenAI-compatible HTTP provider;
- a local provider using the same structured contract.

Only the Mock provider is required for complete offline verification. Optional providers remain disabled until explicitly configured.

Agents receive minimized, sanitized data. They never receive Graph credentials, passwords, tokens, private keys, authorization headers, cookies, full directory dumps, or unrelated PII.

Agent roles are:

- **Intake Agent:** extracts supplied facts, labels inferences, and identifies required human input.
- **Access Planning Agent:** recommends group, license, addition, removal, and discrepancy data.
- **Identity Security Review Agent:** identifies suspicious conditions and policy mismatches.
- **Audit Explanation Agent:** summarizes sanitized JSONL events through a read-only interface.

All outputs use closed schemas with unknown-property rejection and maximum-size limits. Malformed JSON, unknown entitlements, hallucinated identifiers, agent-supplied approval, prompt injection, command text, and policy-override attempts fail closed or require human correction. No output is passed to `Invoke-Expression`, a shell, a PowerShell parser, or a generic Graph request tool.

### Audit architecture

Audit entries include:

- `timestamp`
- `runId`
- `requestId`
- `correlationId`
- `actorType`
- `actorId`
- `action`
- `target`
- `result`
- `riskLevel`
- `policyVersion`
- `schemaVersion`
- `approvalId`
- `planHash`
- `dryRun`
- sanitized `detail`

Actor type is restricted to `Human`, `Automation`, `Agent`, or `ServicePrincipal`.

All audit fields pass through central sanitization. Redaction covers common secret names and token formats, authorization headers, cookies, private-key blocks, client secrets, passwords, and provider prompt bodies. Security-relevant failures are preserved as stable error categories and sanitized messages rather than swallowed.

Audit logs remain local JSONL files. Reports containing identity data remain gitignored and are documented as sensitive operational artifacts.

### Access drift

The drift engine compares expected policy access with observed adapter data and reports:

- expected access
- observed access
- missing access
- excess managed access
- unmanaged access
- privileged access
- stale access

Unmanaged access is reported but never automatically removed. The existing managed-universe model remains authoritative for automated removal. Reports support JSON, CSV, and portfolio-oriented Markdown.

### Nonhuman identity governance

Microsoft currently documents Microsoft Entra Agent ID resources and read operations in Microsoft Graph v1.0. The project will add `Review-AgentIdentities.ps1` as an optional read-only review component using documented v1.0 endpoints through the Graph adapter.

The review checks documented properties when available, including owners or sponsors, lifecycle state, privileges, stale activity, missing accountability, excessive permissions, and governance metadata. The implementation does not create, change, retire, delete, or assign permissions to agent identities.

The documentation labels this area as:

- **Implemented:** schema, mock data, review calculations, and report rendering.
- **Simulated:** tenant-free agent identity fixtures and demo results.
- **Optional:** authenticated read-only Microsoft Graph retrieval.
- **Unsupported:** live creation, mutation, deletion, permission grant, credential management, or automated remediation for Agent ID objects.

Real-tenant behavior remains a production validation gap until tested with a suitably licensed tenant and least-privileged permissions.

## Existing Script Integration

The current entry points remain:

- `Joiner-NewEmployee.ps1`
- `Mover-UpdateEmployee.ps1`
- `Leaver-OffboardEmployee.ps1`
- `Review-AccessReview.ps1`

Each mutating script builds a structured request and plan, evaluates policy and risk, and supplies a verified execution context to the gate. Existing scalar parameters remain supported. New parameters allow request, policy, approval, adapter mode, and mock fixture paths.

`-Force` no longer substitutes for approval. It may suppress an interactive typed prompt only when the policy requires automation mode and a valid structured approval already authorizes the exact plan.

Authentication selection explicitly prefers a configured certificate. Client-secret authentication remains supported as a documented fallback. Tenant identity is validated consistently before Graph connection.

The future-start-date runbook uses a gated lifecycle operation rather than documenting a direct `Update-MgUser` command.

## Failure Behavior

The system fails closed when:

- JSON is malformed;
- schema or configuration validation fails;
- an unknown field or enum is present;
- required authoritative data is missing;
- a referenced user, group, license, role, or manager cannot be uniquely resolved;
- agent output exceeds bounds or violates its schema;
- policy denies an operation;
- SoD conflict handling requires denial or escalation;
- a protected object is targeted;
- risk cannot be classified;
- approval is missing, expired, mismatched, or out of scope;
- a plan hash differs;
- the AI provider fails;
- a Graph read needed for authorization fails;
- the adapter receives an unsupported action;
- a security-relevant exception occurs.

An AI provider failure does not skip validation or authorize a default plan. The operator can proceed without AI by using authoritative structured input.

## Tenant-Free Demo

The demo uses only reserved example identities, the Mock AI provider, Mock Graph adapter, example policy, and local output directories. It requires no tenant, Graph credentials, or AI key.

It covers:

1. standard Joiner;
2. department Mover;
3. standard Leaver;
4. access review;
5. privilege-escalation attempt;
6. prompt-injection attempt;
7. SoD conflict;
8. expired approval;
9. plan tampering;
10. hallucinated entitlement;
11. agent recommendation denied by policy;
12. access-drift report;
13. simulated nonhuman identity review.

Every demo output visibly identifies execution as simulation.

## Testing Strategy

Pester tests run without tenant credentials and mock every external boundary. Coverage includes:

- lifecycle request schema and unknown-property rejection;
- configuration validation;
- policy decisions and policy-over-agent precedence;
- deterministic risk classification;
- protected identities, groups, roles, and service principals;
- SoD denial and escalation;
- canonical serialization and stable plan hashing;
- valid, missing, expired, wrong-request, wrong-scope, and tampered-plan approvals;
- agent schema validation and malformed JSON;
- prompt and command injection;
- hallucinated entitlements and identities;
- audit redaction;
- unbiased password generation properties: requested length, valid alphabet, and differing calls;
- access drift classification and unmanaged-access preservation;
- Graph adapter mocks;
- dry-run enforcement;
- mutation choke-point enforcement;
- tenant-free demo scenarios.

Password tests verify construction properties only and do not claim to prove cryptographic security statistically.

Static validation parses every PowerShell file. PSScriptAnalyzer runs with repository settings. JSON Schema and example configuration files are validated. CI scans tracked content for common committed-secret patterns and confirms that no test imports live Graph modules or requires production credentials.

## Continuous Integration

GitHub Actions uses minimum read-only repository permissions. It installs a pinned PowerShell/Pester/PSScriptAnalyzer toolchain, then runs syntax validation, JSON validation, configuration validation, PSScriptAnalyzer, Pester, agent-boundary tests, demo scenarios, and practical secret scanning.

Third-party actions are pinned to immutable commit SHAs where used. CI receives no tenant IDs, client IDs, certificates, secrets, or AI provider keys and never contacts Microsoft Graph.

## Documentation Deliverables

Update or create:

- `README.md`
- `SECURITY.md`
- `docs/ARCHITECTURE.md`
- `docs/THREAT_MODEL.md`
- `docs/RUNBOOK.md`
- configuration reference and demo documentation

The README opens with the problem, solution, architecture, security model, demo, features, threat model, testing, and limitations. It includes a Mermaid diagram with a visible deterministic enforcement boundary and a section titled `What this project deliberately does not do`.

## Implementation Sequence

1. Request and approval schemas plus strict validation helpers.
2. Policy configuration, policy engine, protected-object controls, and SoD.
3. Risk engine.
4. Canonical plans, SHA-256 hashing, and approval verification.
5. Audit context and sanitization.
6. Strengthened mutation gate and Graph adapter.
7. Existing script integration and unbiased temporary-password generation.
8. Mock Graph and tenant-free core tests.
9. AI provider interface, Mock provider, agents, and security gateway.
10. Adversarial agent tests.
11. Access drift reports.
12. Read-only Agent ID review and mock fixtures.
13. CI.
14. Architecture, threat model, runbook, security policy, demo, and README.
15. Full verification and final security review.

Each stage must keep the repository parseable and testable. Controls are not weakened to make tests pass.

## Acceptance Criteria

Completion requires evidence that:

- dry-run is still the default;
- live mutation still requires `-Apply`;
- all Graph mutations pass through the central gate and adapter;
- policy is authoritative over all agent recommendations;
- protected roles and objects cannot be changed through normal JML;
- unknown entitlements fail closed;
- malformed AI output and prompt injection cannot execute anything;
- High and Critical plans require valid approval;
- expired approvals and altered plans fail;
- unmanaged access is never silently removed;
- audit output redacts common secret forms;
- CI and demos need no tenant credentials or AI key;
- examples and fixtures contain synthetic identities only;
- Agent ID claims accurately distinguish implemented, simulated, optional, unsupported, and unverified behavior;
- Pester, PSScriptAnalyzer, syntax, schema, configuration, and demo checks pass in the documented PowerShell runtime.

## Deliberate Limitations

- LLMs cannot directly mutate Microsoft Entra ID.
- AI output is not authorization.
- The project does not execute agent-generated commands.
- Unknown entitlements are not guessed.
- The demo does not pretend to perform live Graph execution.
- CI does not contact a production tenant.
- Unmanaged access is not automatically removed.
- Privileged roles cannot be assigned through ordinary JML flows.
- Plan hashes provide integrity comparison, not signer authentication.
- Live Graph behavior, permissions, and Agent ID tenant behavior require separate production validation.

