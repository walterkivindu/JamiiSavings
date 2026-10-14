# Jamii Savings Integrations

Three integrations built on WSO2 Micro Integrator 4.6.0, published through WSO2 API Manager 4.7.0, and deployed by one Jenkins pipeline.

| API | MI resource | Backend | APIM security | Tier |
|---|---|---|---|---|
| 1a Accounts | `GET /accounts/{accountNumber}/balance` | MySQL 8 via an MI data service | OAuth2 | Gold |
| 1b Customers | `GET /customers/{customerId}` | JSONPlaceholder `/users/{id}` (REST) | OAuth2 or API key | Gold |
| 1c Loans | `POST /loans/eligibility` | DNE Online Calculator (SOAP 1.1) | API key | **JamiiSoapLimited** (10/min) |

Through the gateway: `https://localhost:8243/{accounts|customers|loans}/v1/...`. The API Product is at `/jamii/v1/...`.

## Run it locally

Prerequisites: Docker (about 4 GB free RAM with APIM), JDK 21, bash (Git Bash on Windows), curl and python3.

```bash
./mvnw clean install -DskipTests           # builds target/JamiiSavings_1.0.0.car
docker compose up -d                        # MySQL (schema + seed auto-loaded) and MI
bash tests/smoke.sh                         # 19 curl checks against MI + log-masking check
FAULT_TESTS=1 bash tests/smoke.sh           # 24: adds DB down, backend timeout/down (restarts containers)

docker compose --profile apim up -d apim    # APIM 4.7.0 (about 2 min to become healthy)
bash scripts/package-apim.sh                # apictl bundles in target/apim/
bash scripts/deploy-apim.sh dev             # tier, policy, 3 APIs, API Product
GATEWAY=1 bash tests/smoke.sh               # 22: same checks through the gateway, real OAuth2 token / API key
```

APIM consoles: `https://localhost:9443/publisher` and `https://localhost:9443/devportal` (admin/admin). `tests/smoke.sh` is also the script for the screen recording.

## Architecture and trade-offs

- **One shared error contract.** Every failure path sets `httpStatus`, `errCode` and `errMsg`, then calls `ErrorSequence`. It is also each API's fault handler and the only place an error body is built: `{"error":{"code","message","requestId","timestamp"}}`. It also strips all request and backend headers, so nothing leaks through error responses. Errors are the same shape for DB, HTTP and SOAP backends: 400 for bad input, 404 not found, 502 upstream fault, 503 unavailable, 504 timeout.
- **1a: data service, not DBLookup.** `AccountDataService` uses a parameterized `WHERE account_number = ?` on the `JamiiDS` datasource. The API validates first (`^[0-9]{10}$` gives 400), and an empty result gives 404. If the data service faults or returns non-200, the API answers **503 `DB_UNAVAILABLE`**, distinct from 404/500. Trade-off: an internal HTTP hop (MI → its own data service) in exchange for a reusable, separately testable data layer.
- **1b: allowlist header handling.** The API drops *all* inbound transport headers (Authorization, X-JWT-Assertion, X-Internal-*, Cookie, …) before the public backend. It then sets only `Accept` and `X-Correlation-ID`, using the caller's ID or minting one. Backend response headers (Set-Cookie, CF-*) are also dropped. I verified what the backend actually receives by pointing it at postman-echo. The endpoint has a 5 s timeout (504), a connect failure gives 503, and backend 404 maps to our 404.
- **Per-environment backends** come in through env vars (`$SYSTEM:CUSTOMERS_BACKEND_URL`, `$SYSTEM:CALCULATOR_SOAP_URL`), so the same CAR goes to every environment. The fault tests use this to point MI at a slow or dead host.
- **PII masking, two layers.** Mediation logs mask explicitly (`MaskSequence`: `100*****01`). Separately, `mi/conf/log4j2.properties` wraps every appender with a regex mask for 10-digit numbers and email local parts. The second layer was needed because the MI 4.6 Log mediator prefixes each line with the full request path (`GET /accounts/1000000001/balance`). The smoke test fails if any raw account number, customer ID or email reaches MI logs (the mask also covers MI's HTTP access log).
- **1c in script mediators.** Validation and arithmetic sit in a small script mediator. I tried 4.6 Synapse expressions first, but they failed on numbers above Int32, and `&&` binds tighter than comparisons, so this was simpler and more readable.
- **Timeouts:** `synapse.timeout_handler_interval` is lowered to 1 s in `deployment/deployment.toml`. With the default 15 s sweep, the 5 s endpoint timeout wasn't enforced (an 8 s backend returned 200).

### 1b backend: JSONPlaceholder (`https://jsonplaceholder.typicode.com/users/{id}`)
It's free, stable, needs no key, and returns realistic customer PII (name, email, phone, address). That makes it a fair test of log masking. It also returns a real 404 for unknown IDs, so I could show backend-404 → our 404 mapping.

### 1c SOAP service: DNE Online Calculator (`http://www.dneonline.com/calculator.asmx`)
It's one of the few public SOAP 1.1 services that is reliably up. More importantly, it raises **genuine SOAP Faults**: for Int32 overflow it returns a fault containing a .NET stack trace, which is exactly the leak the brief warns about.
**Mapping:** `monthlyInstallment = Divide(requestedAmount, termMonths)` comes from the SOAP call. MI computes `maxAffordableInstallment = 50% × (monthlyIncome − monthlyObligations)`, and the applicant is eligible if the installment fits. The backend does one meaningful calculation, and the business rule stays in our layer where it can change. A SOAP Fault becomes **502 `UPSTREAM_FAULT`** with a generic message. Only the `faultcode` is logged server-side, and the fault XML never reaches the client. Inputs outside our own rules (e.g. `termMonths: 0`) are rejected with 400 before the SOAP call. An amount we accept but the backend can't handle (e.g. 5,000,000,000 overflows Int32) demonstrates the fault mapping.

## API Manager

- **OpenAPI:** hand-written in `apim/openapi/`, copied into each apictl project (`apim/apis/*`) at packaging time.
- **Security:** Accounts uses OAuth2 only (balances are user data, so token-based). Customers accepts OAuth2 or an API key. Loans uses an API key only (a machine-to-machine style partner check). Both rejections are tested: an API key on Accounts gives 401, and a token on Loans gives 401.
- **Throttling:** Accounts and Customers use the built-in Gold tier. **LoansAPI uses a custom `JamiiSoapLimited` tier (10 req/min) because every call fans out to a slow, free third-party SOAP service we must not hammer.** I verified the 11th call in a minute returns 429.
- **Custom gateway policy:** `jamiiCorrelationId` is a common operation policy on AccountsAPI's request flow. It injects `X-Correlation-ID` when missing, strips `X-Debug` and `X-Internal-Token`, and logs the ID at the gateway.
- **API Product:** `JamiiSavingsProduct` (`/jamii/v1`, Silver tier) groups all three. A partner app subscribes once and gets the whole "savings customer" capability, while the individual APIs stay available for consumers that need only one.
- **Discover and subscribe (Dev Portal):** sign in at `/devportal` → browse or search by tag `jamii` → open an API or the product, and read its OpenAPI doc or try it → *Applications* → create an app → *Subscribe* the app to an API or the product, picking a tier it offers → *Production Keys* → generate keys (consumer key/secret, then a token via client_credentials) or generate an API key → call the gateway with `Authorization: Bearer …` or `apikey: …`. `scripts/apim_consumer.py` runs exactly this flow over the Dev Portal REST API, and the gateway tests use it.

## Pipeline (`Jenkinsfile`)

One declarative pipeline drives all three APIs from a single `APIS` list. Stages: Build CAR (`mvnw clean install`) → Package APIM (`apictl bundle`, all three validated before anything is deployed) → start the dev compose stack → deploy MI → MI smoke tests → deploy APIM (tier → policy → APIs → product, `apictl import --update` with per-env params) → gateway smoke tests → manual approval → prod.
**No silent partial deploys:** all three APIs ship in one CAR, so the MI deploy is atomic. APIM is only touched after MI tests pass. `deploy-apim.sh` stops at the first failed import, exits non-zero and lists what was applied (verified with a corrupted bundle). On failure, the `post` block re-imports the last successful build's bundles. The stage logic lives in `scripts/` so it runs identically on a laptop. I ran every stage in order from a clean stack (`down -v`, blank APIM): build, package, MI deploy, 19/19 MI checks, APIM deploy, 22/22 gateway checks.

## Assumptions

- Account numbers are exactly 10 digits, and currency is always KES.
- Customer IDs are numeric to match the JSONPlaceholder backend. Loan amounts are whole KES with terms of 1–360 months.
- The credentials in the repo (`jamii/jamiipw`, `admin/admin`) are for the local stack only. Real environments use Jenkins credentials or a secret vault.

## What is not verified / known gaps

- **Jenkins itself was not run** (no Jenkins available). Every stage's commands were run locally in order against a clean stack. The prod stage is conceptual: it refuses to run without a configured prod MI target (`PROD_MI_DEPLOY_CMD`) and the `jamii-apim-prod` credential, and the Jenkins rollback path is untested.
- An unreachable backend *host* (connect timeout) returns 503 only after about 15 s. That's the transport connect timeout, which isn't configurable per endpoint.
- APIM's own errors (401, 429) use APIM's JSON format, not ours. APIM's logs (e.g. auth-failure WARN lines) can include the request path, which contains the account number; only MI's logs are masked.
- Windows `apictl` 4.7.2 rejects valid policy directories (a path-separator bug), so `scripts/apictl.sh` runs the Linux binary in a container.
- Bonus A and B were not attempted.

## With more time

- Map APIM 401/429 bodies to the Jamii error shape with a custom fault sequence.
- Apply the same log4j2 mask to APIM, or move the account number out of the URL.
- Add MI unit tests (synapse-unit-test) for the mediation logic.
- Use secrets via `wso2-vault` or env, not files; add TLS to MI.
- Add a gateway-level `jsonValidator` for Loans so bad bodies are rejected before MI.
- Replace the public demo backends with contract-tested mocks in CI.
