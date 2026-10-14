#!/usr/bin/env python3
"""
Scripted version of the Developer Portal consumer flow, against APIM 4.7 REST APIs:

  1. Register a REST client (DCR) and get a token for the Dev Portal / Publisher APIs
  2. Create (or reuse) an application "JamiiSmokeApp"
  3. Subscribe it to AccountsAPI, CustomersAPI, LoansAPI (and the API Product if present)
  4. Generate PRODUCTION OAuth2 keys, get an access token (client_credentials)
  5. Generate an API key for the app

Prints shell exports (ACCESS_TOKEN, API_KEY) for tests/smoke.sh through the gateway.

  python scripts/apim_consumer.py [--apim https://localhost:9443] [--create-product]

Standard library only (no pip install needed in CI).
"""
import argparse, base64, json, ssl, sys, urllib.parse, urllib.request

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE  # local APIM uses its default self-signed cert

APIS = ["AccountsAPI", "CustomersAPI", "LoansAPI"]
PRODUCT = "JamiiSavingsProduct"
APP = "JamiiSmokeApp"


def call(method, url, token=None, basic=None, body=None, form=None, ok=(200, 201, 202)):
    headers = {"Accept": "application/json"}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if basic:
        headers["Authorization"] = "Basic " + base64.b64encode(basic.encode()).decode()
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    if form is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        data = urllib.parse.urlencode(form).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
            raw = r.read().decode() or "{}"
            return r.status, json.loads(raw) if raw.strip().startswith(("{", "[")) else raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        if e.code in ok:
            return e.code, json.loads(raw or "{}")
        sys.exit(f"FAIL {method} {url} -> {e.code}: {raw[:400]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apim", default="https://localhost:9443")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--create-product", action="store_true",
                    help="create the API Product via Publisher REST (one-off, then export it with apictl)")
    a = ap.parse_args()
    pub = f"{a.apim}/api/am/publisher/v4"
    dev = f"{a.apim}/api/am/devportal/v3"

    # 1. DCR + password grant for the management scopes we need
    _, reg = call("POST", f"{a.apim}/client-registration/v0.17/register", basic=f"{a.user}:{a.password}",
                  body={"callbackUrl": "www.example.com", "clientName": "jamii_rest_client", "owner": a.user,
                        "grantType": "password refresh_token client_credentials", "saasApp": True})
    scopes = ("apim:api_view apim:api_create apim:api_publish apim:api_product_import_export apim:subscribe "
              "apim:app_manage apim:sub_manage apim:api_key")
    _, tok = call("POST", f"{a.apim}/oauth2/token", basic=f"{reg['clientId']}:{reg['clientSecret']}",
                  form={"grant_type": "password", "username": a.user, "password": a.password, "scope": scopes})
    admin = tok["access_token"]

    # Discover API ids from the Dev Portal (what a consumer would browse)
    _, found = call("GET", f"{dev}/apis?limit=50", token=admin)
    ids = {x["name"]: x["id"] for x in found["list"]}
    missing = [n for n in APIS if n not in ids]
    if missing:
        sys.exit(f"FAIL: not visible in Dev Portal yet: {missing}")
    print(f"# Dev Portal lists: {', '.join(sorted(ids))}", file=sys.stderr)

    if a.create_product:
        _, papis = call("GET", f"{pub}/apis?limit=50", token=admin)
        pids = {x["name"]: x["id"] for x in papis["list"]}
        prod_apis = []
        for n in APIS:
            _, d = call("GET", f"{pub}/apis/{pids[n]}", token=admin)
            prod_apis.append({"apiId": pids[n],
                              "operations": [{"target": o["target"], "verb": o["verb"]} for o in d["operations"]]})
        _, existing = call("GET", f"{pub}/api-products?query={PRODUCT}", token=admin)
        if existing.get("count", 0) == 0:
            _, prod = call("POST", f"{pub}/api-products", token=admin, body={
                "name": PRODUCT, "context": "/jamii", "version": "v1",
                "description": "Jamii Savings: accounts, customers and loan eligibility as one subscribable product.",
                "policies": ["Silver"], "securityScheme": ["oauth2", "api_key", "oauth_basic_auth_api_key_mandatory"],
                "visibility": "PUBLIC", "apis": prod_apis})
            pid = prod["id"]
            _, rev = call("POST", f"{pub}/api-products/{pid}/revisions", token=admin, body={"description": "initial"})
            call("POST", f"{pub}/api-products/{pid}/deploy-revision?revisionId={rev['id']}", token=admin,
                 body=[{"name": "Default", "vhost": "localhost", "displayOnDevportal": True}])
            print(f"# Created and deployed API Product {PRODUCT}", file=sys.stderr)
        return

    # 2. Application
    _, apps = call("GET", f"{dev}/applications?query={APP}", token=admin)
    old = next((x for x in apps["list"] if x["name"] == APP), None)
    if old:  # disposable test consumer: recreate so keys/secrets are always fresh
        call("DELETE", f"{dev}/applications/{old['applicationId']}", token=admin)
    _, app = call("POST", f"{dev}/applications", token=admin,
                  body={"name": APP, "throttlingPolicy": "Unlimited", "description": "smoke test consumer",
                        "tokenType": "JWT"})
    app_id = app["applicationId"]

    # 3. Subscriptions (tier per API = the tier the API offers)
    _, subs = call("GET", f"{dev}/subscriptions?applicationId={app_id}", token=admin)
    have = {s["apiId"] for s in subs["list"]}
    for n in APIS + ([PRODUCT] if PRODUCT in ids else []):
        if ids[n] in have:
            continue
        _, api = call("GET", f"{dev}/apis/{ids[n]}", token=admin)
        tier = api["tiers"][0]["tierName"]
        call("POST", f"{dev}/subscriptions", token=admin,
             body={"applicationId": app_id, "apiId": ids[n], "throttlingPolicy": tier})
        print(f"# Subscribed {APP} -> {n} ({tier})", file=sys.stderr)

    # 4. OAuth2 keys + token
    _, prod_keys = call("POST", f"{dev}/applications/{app_id}/generate-keys", token=admin, body={
        "keyType": "PRODUCTION", "keyManager": "Resident Key Manager",
        "grantTypesToBeSupported": ["client_credentials", "password", "refresh_token"],
        "validityTime": 3600, "scopes": ["default"]})
    _, at = call("POST", f"{a.apim}/oauth2/token",
                 basic=f"{prod_keys['consumerKey']}:{prod_keys['consumerSecret']}",
                 form={"grant_type": "client_credentials"})

    # 5. API key
    _, ak = call("POST", f"{dev}/applications/{app_id}/api-keys/PRODUCTION/generate", token=admin,
                 body={"keyName": "smoke-key", "validityPeriod": 3600})

    print(f"export ACCESS_TOKEN='{at['access_token']}'")
    print(f"export API_KEY='{ak['apikey']}'")


if __name__ == "__main__":
    main()
