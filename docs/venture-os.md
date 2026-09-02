# VentureOS Foundation

VentureOS is an Agentic Venture Studio OS: a repeatable, governed platform for
launching multiple revenue ventures, operating them with specialized agents,
and using real ventures as proof that the system works.

## Hierarchy

| Layer | Meaning | Isolation responsibility |
|---|---|---|
| Organization | Tenant, owner, or future white-label customer | Branding, catalog visibility, tenant boundary |
| Venture | One revenue thesis or operating company | Venture lifecycle, blueprint, budget, KPIs |
| Workspace | Department, client delivery area, or internal platform function | Work, state, messages, approvals, audit |
| Agent | Durable bounded role | Identity, authority, capabilities, credential |
| Model deployment | Replaceable execution engine | Capabilities, price, latency, privacy, availability |

The cybersecurity intelligence studio is venture one. It validates VentureOS;
it does not define or limit the platform.

## Repeatability and white-label seams

Versioned venture blueprints describe the departments, agent roles, and default
controls a new venture needs. Instantiation records which exact blueprint
version produced which resources. Credentials are issued afterward through the
gateway so a blueprint can never leak or clone a secret.

Brand profiles exist at tenant and venture scope. Custom domains, customer
billing, tenant self-service, and dedicated deployments are deliberately later
layers; v0.4 establishes their data boundaries without pretending those product
features already exist.

## Model-agnostic execution

The durable identity is the job role, not a provider-specific Bot. For each
task class, a task profile declares:

- required capabilities and data classification;
- minimum quality and maximum latency;
- maximum cost, turns, and tool calls;
- allowed providers and models;
- risk tier and approval expectations.

A routing policy scores only eligible deployments. The decision stores all
candidates, the selected model, the price snapshot, token estimate, policy
version, and reason. Eval results and usage ledger entries then provide evidence
for future routing changes.

## Cost containment

Before execution, the router reserves estimated cost atomically against a hard
budget. That prevents two concurrent agents from spending the same remaining
balance. On completion, actual cost settles the reservation; unused
reservations expire and release capacity. The runtime must still use provider
token limits because a database reservation cannot stop a provider request that
has already exceeded its declared maximum.

## Deliberate compatibility boundary

v0.4 does not change existing claim or lease semantics. Current agents keep
their home workspace and keys. Multi-workspace memberships are recorded now,
but cross-workspace claiming should be enabled only with an explicit gateway
authorization rule and its own security tests.
