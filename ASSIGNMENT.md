# Practical Assignment: Jamii Savings Integrations

**From:** Family Bank, System Integrations (appraisal@familybank.co.ke)
**Sent:** 7 Oct 2026
**Deadline:** 14 October 2026
**Submit to:** appraisal@familybank.co.ke
**Submission format:** Git repository link

## Scenario

Build three integrations for a fictional bank, **Jamii Savings**, using **WSO2 Micro Integrator (MI)**, then expose and manage them through **WSO2 API Manager (APIM)**, and automate the build/deploy process with a **Jenkins pipeline**.

---

## Part 1: Micro Integrator Services

### 1a. DB-backed API: `GET /accounts/{accountNumber}/balance`

Use MI's data services (or a datasource + query artifact) to query a database for an account record. A SQLite or embedded H2/MySQL setup is fine. Include your schema and seed script so it is self-contained.

Return the result in this envelope:

```json
{
  "accountNumber": "string",
  "status": "ACTIVE | DORMANT | CLOSED",
  "balance": { "amount": 0.00, "currency": "KES" },
  "requestId": "uuid",
  "timestamp": "ISO-8601"
}
```

- Use parameterized queries.
- Return **404** for an unknown account.
- Return a **distinct error response** for a DB-level failure.

### 1b. Proxy API: `GET /customers/{customerId}`

Front an existing public mock REST API of your own choice with a pass-through/managed proxy in MI. **Name your chosen backend and why in your write-up.**

Add real gateway value:

- Header manipulation (e.g. inject a correlation ID if the caller didn't send one; strip internal headers)
- Timeout configuration
- A fault sequence for backend unavailability

### 1c. SOAP-to-REST transformation: `POST /loans/eligibility`

Accept a REST/JSON request, call a public SOAP test service of your own choice to perform the "eligibility check", and transform the SOAP response into clean JSON. **Name your chosen service and briefly justify the mapping in your write-up.**

Map any SOAP Fault to a sane REST error response. Don't leak raw SOAP fault XML to the client.

### Across all three

- Log key points (request in, backend call, response out), **masking sensitive fields** (account numbers, customer PII).
- Return **400** for malformed input, not 500.
- Keep the **error response shape consistent** across all three APIs, even though the backends differ (DB, HTTP, SOAP).

---

## Part 2: Expose through API Manager

Publish all three as managed APIs in APIM. For each:

- A usable **OpenAPI/Swagger definition** (hand-written or exported, but accurate)
- A **security scheme** (API Key or OAuth2; your choice; it doesn't have to be the same for all three)
- A **rate-limiting/throttling tier**. At least one API should use a different tier than the others, with a one-line reason in your write-up.

Additionally:

- Apply at least one **custom gateway-level mediation policy** to one of the APIs (e.g. header injection, a validation policy, or a custom sequence).
- Group all three under a single **API Product**, or explain in your write-up why you chose not to.
- Briefly document how a consuming application would **discover and subscribe** to these APIs via the Developer Portal.

---

## Part 3: Pipeline

Build a **single Jenkins pipeline** (a `Jenkinsfile`, declarative or scripted) that handles all three APIs, **not three separate copy-pasted pipelines**:

1. **Build/package** the MI artifacts (`mvn clean install` with the WSO2 Maven plugins, or equivalent)
2. **Package/export** each APIM API artifact (API archives or an `apictl` project covering all three)
3. **Run any available tests**
4. **Deploy** the MI composite application(s) to a target MI runtime, and import/update all three API definitions in APIM, using `apictl` or equivalent
5. **Separate environments** conceptually (e.g. dev → prod stages), even if only dev is actually wired up
6. **Fail the pipeline cleanly** if any one of the three deployments fails. Don't silently partial-deploy.

A live, permanently-running target environment isn't required. A docker-compose setup (MI + APIM + the DB) that you spin up locally/in CI to deploy against is fine.

---

## Bonus (optional)

Not required. Attempt only if you have time left after the core assignment.

### Bonus A: Aggregation API: `GET /customers/{customerId}/dashboard`

Call two or more of the Part 1 backends in parallel, and merge the results into one combined response.

Decide and justify in your write-up: if one call fails or times out, does the API return **partial data** (with the failed section flagged) or **fail the whole response**?

### Bonus B: Message Queue Integration

Consume a message from a queue/topic (JMS, Kafka, RabbitMQ; your choice; a local broker via Docker Compose is fine) representing a **loan application event**, transform it, and either call one of the Part 1 APIs or publish to another topic.

Handle a malformed/unprocessable message properly (dead-letter queue or equivalent) rather than silently dropping it.

In your write-up, briefly explain how this differs from your request/response APIs in terms of error handling and retries.

---

## Write-up

Include a `README.md` (half a page to a page) covering:

- Architecture decisions and trade-offs
- What you'd do differently with more time
- Any assumptions you made
- How to run everything locally

## What to submit

A Git repository link containing:

- [ ] MI project with all three integrations
- [ ] DB schema + seed script for the DB-backed API
- [ ] APIM API definitions / `apictl` project for all three (and the API Product, if used)
- [ ] `Jenkinsfile`
- [ ] `README.md`
- [ ] A short **screen recording (5 min)** walking through a live call to each of the three APIs

## Items the write-up must explicitly cover (collected from above)

- Chosen backend for 1b and why
- Chosen SOAP service for 1c and a brief justification of the mapping
- One-line reason for the different throttling tier on at least one API
- API Product grouping, or why it was not used
- Developer Portal discovery and subscription flow
- (Bonus A) Partial data vs fail-whole decision and justification
- (Bonus B) How queue error handling/retries differ from request/response APIs