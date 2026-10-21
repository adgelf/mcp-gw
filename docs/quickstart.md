# Quickstart

Get the MCP gateway running, wire up identity and provider OAuth, and connect an
MCP client. The gateway exposes one public `/mcp` endpoint. Callers authenticate
with a bearer token (HOP-1); each enabled downstream provider exposes a stable
tool catalog while provider credentials are checked only when a tool is called.

Two credential hops:

- **HOP-1 (client to gateway):** the MCP client presents a bearer token from an
  issuer you configure (Google OIDC, Okta, Entra, or a purpose-built identity
  service). It identifies the caller and is never forwarded downstream.
- **HOP-2 (wrapper to Google):** the Google Workspace wrapper mints short-lived
  Google access tokens from a per-user refresh token stored under the HOP-1
  principal.

---

## 1. Install

### Path A — local Docker Compose (evaluation)

```bash
cp deploy/compose/.env.example deploy/compose/.env
# edit deploy/compose/.env, then:
docker compose -f deploy/compose/docker-compose.yaml up
```

Compose starts three services: `agentgateway` (published on `GATEWAY_PORT`,
default `8080`), the `google-workspace` wrapper, and a `token-store` PostgreSQL
instance seeded with the OAuth schema. The gateway serves MCP at
`http://localhost:8080/mcp`.

Fill in at least these `.env` values before starting (see [Setup](#2-setup) for
what each one is):

```dotenv
# HOP-1 caller identity (single-issuer form)
HOP1_ISSUER=https://identity.example.com
HOP1_JWKS_URL=https://identity.example.com/.well-known/jwks.json
HOP1_AUDIENCE=https://mcp.example.com/mcp
HOP1_ALLOWED_ALGORITHMS=EdDSA

# Google Workspace OAuth consent app (HOP-2)
GOOGLE_OAUTH_CLIENT_ID=<google-oauth-client-id>
GOOGLE_OAUTH_CLIENT_SECRET=<google-oauth-client-secret>
GOOGLE_OAUTH_REDIRECT_URI=https://mcp.example.com/oauth/google/callback

# 32 random bytes, base64 (openssl rand -base64 32)
GOOGLE_TOKEN_ENCRYPTION_KEY=<base64-32-bytes>

# Token store DSN (default points at the bundled postgres service)
TOKEN_STORE_DSN=postgres://mcp:mcp@token-store:5432/mcp
```

For multiple issuers use `HOP1_ISSUERS_JSON` instead of the single `HOP1_*`
fields; see the commented example in `deploy/compose/.env.example`. To also run
the GitHub MCP backend locally, use the `deploy/compose/docker-compose.github-mcp.yaml`
overlay and fill the `GITHUB_*` values.

### Path A, variant — Compose with the built-in OAuth broker

Use this when you have no OIDC provider to register and only need Google
Workspace. Google signs the user in, the wrapper's built-in broker issues the
HOP-1 token, and MCP clients that support OAuth discovery and dynamic client
registration connect without a pre-minted token. Leave the `HOP1_*` values
empty; do not use `https://accounts.google.com` as a HOP-1 issuer.

The broker rejects loopback, private, and non-HTTPS hosts, so the issuer,
resource, and callback must share one public HTTPS origin. For local
evaluation, publish `GATEWAY_PORT` through an HTTPS tunnel with a stable
hostname (for example an ngrok reserved domain:
`ngrok http --url=<public-host> 8080`). The examples below use
`mcp.example.com`.

1. Create a signing key outside the repository (any Node.js 18+):

   ```bash
   mkdir -p ~/.config/mcp-gw/broker && chmod 700 ~/.config/mcp-gw/broker
   KID=local-broker-1 OUT=~/.config/mcp-gw/broker/signing-jwks.json node -e '
   const { generateKeyPairSync } = require("node:crypto");
   const { writeFileSync } = require("node:fs");
   const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
   const jwk = { ...privateKey.export({ format: "jwk" }), kid: process.env.KID, alg: "RS256", use: "sig" };
   writeFileSync(process.env.OUT, JSON.stringify({ keys: [jwk] }) + "\n", { flag: "wx", mode: 0o600 });
   '
   ```

2. Copy the gateway template and set your host:

   ```bash
   sed 's/mcp\.example\.com/<public-host>/g' gateway/agentgateway/local-broker.yaml \
     > ~/.config/mcp-gw/agentgateway-broker.yaml
   ```

   It authenticates `/mcp` against the broker and passes the broker routes
   (`/oauth/authorize`, `/oauth/token`, `/oauth/register`, metadata, JWKS) and
   both Google callbacks through to the wrapper.

3. Register both redirect URIs on the Google OAuth client (see
   [Google OAuth client](#google-oauth-client-hop-2)):
   `https://<public-host>/oauth/google/broker/callback` and
   `https://<public-host>/oauth/google/callback`.

4. Add to `deploy/compose/.env` alongside the `GOOGLE_*` values:

   ```dotenv
   GOOGLE_OAUTH_REDIRECT_URI=https://mcp.example.com/oauth/google/callback
   MCP_AUTHORIZATION_ISSUER=https://mcp.example.com/oauth
   MCP_RESOURCE_URI=https://mcp.example.com/mcp
   MCP_BROKER_GOOGLE_REDIRECT_URI=https://mcp.example.com/oauth/google/broker/callback
   MCP_BROKER_ACTIVE_KID=local-broker-1
   LOCAL_BROKER_SIGNING_JWKS_DIR=/Users/<you>/.config/mcp-gw/broker
   BROKER_GATEWAY_CONFIG=/Users/<you>/.config/mcp-gw/agentgateway-broker.yaml
   ```

5. Start with the overlay and point the client at the public URL:

   ```bash
   docker compose -f deploy/compose/docker-compose.yaml \
     -f deploy/compose/docker-compose.broker.yaml up -d --build
   claude mcp add --transport http mcp-gw https://mcp.example.com/mcp
   ```

   `curl https://<public-host>/.well-known/oauth-protected-resource/mcp` should
   list `https://<public-host>/oauth` under `authorization_servers`.

On macOS, set `AUDIT_LOG_DIR` to a directory you own (for example
`~/.config/mcp-gw/audit`); the default `/var/log/mcp-gw` does not exist there,
and an unwritable audit log fails every audited tool call. For the Kubernetes
form of this mode see
[`customer-google-broker-deployment.md`](customer-google-broker-deployment.md).

### Path B — Kubernetes via Helm (OCI)

The Helm chart requires Kubernetes 1.32 or newer.

The chart is disabled by default and validated against a JSON schema: enabling
any workload requires at least one complete `hop1.issuers` entry.

```bash
helm install mcp-gateway \
  oci://ghcr.io/apelogic-ai/charts/mcp-gateway \
  --version 0.6.1 \
  -f my-values.yaml
```

Minimal `my-values.yaml` for Google Workspace:

```yaml
hop1:
  issuers:
    - name: workforce
      issuer: https://identity.example.com
      audiences:
        - https://mcp.example.com/mcp
      jwksUrl: https://identity.example.com/.well-known/jwks.json
      allowedAlgorithms:
        - EdDSA
      emailClaim: email
      subjectClaim: sub

agentgateway:
  enabled: true
  image:
    repository: ghcr.io/apelogic-ai/mcp-gw-agentgateway
    tag: "0.6.1"
  mcpAuthentication:
    resourceMetadata:
      resource: https://mcp.example.com/mcp
      scopesSupported:
        - openid
        - email
  backends:
    - name: google-workspace
      enabled: true
      serviceName: google-workspace
      port: 8080
      path: /mcp

googleWorkspace:
  enabled: true
  image:
    repository: ghcr.io/apelogic-ai/mcp-gw-google-workspace
    tag: "0.6.1"
  secretRef:
    name: mcp-provider-runtime

# Run OAuth schema migrations against the token store
oauthMigrations:
  enabled: true
  secretKeyRef:
    name: mcp-oauth-database
    key: dsn
```

Verify:

```bash
helm upgrade --install mcp-gateway oci://ghcr.io/apelogic-ai/charts/mcp-gateway \
  --version 0.6.1 -f my-values.yaml
kubectl rollout status deploy/mcp-gateway-agentgateway
```

The agentgateway Service is `ClusterIP` by default. Reach `/mcp` by enabling
`agentgateway.ingress`, fronting the Service with your own gateway, or during
testing with `kubectl port-forward svc/mcp-gateway-agentgateway 8080:8080`.

When the OAuth broker is enabled, its unauthenticated routes (`/authorize`,
`/token`, `/register`, jwks, callback, and authorization-server metadata) are
served on a dedicated Ingress. Configure transport-level protections there —
such as a small request-body cap and a coarse per-IP rate limit — through
`agentgateway.ingress.brokerAnnotations` (the exact annotation keys are
ingress-controller-specific). These caps never touch `/mcp`, which keeps
carrying large MCP tool payloads, and they complement the semantic, durable
limits the wrapper itself enforces.

---

## 2. Setup

### HOP-1 issuer (bearer-token identity)

Every enabled workload validates inbound bearer tokens against `hop1.issuers`.
Each entry needs an issuer URL, at least one audience, a JWKS URL, and a non-empty
algorithm allowlist. The audience should be your public MCP URL.

```yaml
hop1:
  issuers:
    - name: workforce
      issuer: https://identity.example.com
      audiences:
        - https://mcp.example.com/mcp
      jwksUrl: https://identity.example.com/.well-known/jwks.json
      allowedAlgorithms:
        - EdDSA # RS256/384/512, PS*, ES256/384, or EdDSA
      discoverable: true # advertise in protected-resource metadata
      emailClaim: email
      subjectClaim: sub
```

For issuers that require immediate revocation, add an `introspection` block with
a `url` and a `credentialSecretKeyRef` pointing at an existing Secret key. A full
multi-issuer example is in
[`deploy/k8s/examples/values-enterprise-contract.example.yaml`](../deploy/k8s/examples/values-enterprise-contract.example.yaml).
Keep `agentgateway.mcpAuthentication.resourceMetadata.resource` set to the public
MCP URL and `scopesSupported` aligned with the wrapper identity scopes (`openid`,
`email` by default). Use an immutable `subjectClaim` where possible.

#### Register your identity provider

The gateway **validates** HOP-1 tokens; it never issues them. Create an
OIDC/OAuth application in your own identity provider that mints tokens for the
MCP audience, then copy its published values into a `hop1.issuers` entry. This
works with any standards-compliant OIDC provider (Google OIDC, Okta, Entra ID,
Auth0, Keycloak, or a purpose-built service).

Generic checklist — every value maps to one `hop1.issuers` field:

1. Create an application (or API/resource) representing the MCP gateway. Set its
   identifier/audience to your public MCP URL, e.g. `https://mcp.example.com/mcp`
   → `audiences`.
2. Read the provider's discovery document at
   `<issuer>/.well-known/openid-configuration`. Its `issuer` value → `issuer`,
   and its `jwks_uri` → `jwksUrl`.
3. Confirm the token signing algorithm (commonly `RS256`, `ES256`, or `EdDSA`)
   → `allowedAlgorithms`. List only the algorithms you accept.
4. Ensure issued tokens carry a stable, immutable subject claim (`sub`) and, when
   available, an `email` claim → `subjectClaim` / `emailClaim`.
5. Grant the users or services that will call the gateway permission to obtain
   tokens for that audience.
6. Optional: set `discoverable: true` so the gateway advertises this issuer in
   its protected-resource metadata for MCP clients that self-discover OAuth.

Worked example (Okta):

- Create an **API Services / OAuth 2.0** app; add a **custom authorization
  server** (or use `default`) whose **Audience** is `https://mcp.example.com/mcp`.
- `issuer` = `https://<your-org>.okta.com/oauth2/<auth-server-id>` (or the
  org issuer). `jwksUrl` = that issuer's `/v1/keys`. `allowedAlgorithms: [RS256]`.
- Add a claim mapping so tokens include `email`; keep `sub` as the immutable user
  ID. Assign the app to the users/groups that may reach the gateway.

Entra ID and Auth0 follow the same shape — take `issuer` and `jwks_uri` from the
tenant's `.well-known/openid-configuration`, set the audience/App ID URI to the
MCP URL, and confirm the signing algorithm.

### Google OAuth client (HOP-2)

Create a Google OAuth client (web application) and set its authorized redirect
URI to `https://<your-mcp-host>/oauth/google/callback`. The wrapper reads these
from environment:

```dotenv
GOOGLE_OAUTH_CLIENT_ID=<google-oauth-client-id>
GOOGLE_OAUTH_CLIENT_SECRET=<google-oauth-client-secret>
GOOGLE_OAUTH_REDIRECT_URI=https://mcp.example.com/oauth/google/callback
GOOGLE_TOKEN_ENCRYPTION_KEY=<base64-32-bytes>   # openssl rand -base64 32
```

On Kubernetes, put these (plus `TOKEN_STORE_DSN`) in an existing Secret and
reference it with `googleWorkspace.secretRef.name`. The chart never creates these
credentials. Leave `GOOGLE_OAUTH_SCOPES` unset to keep the full generated consent
scope set; narrowing it disables the `gws_*` tools whose scopes it drops.

### Token store (PostgreSQL)

Per-user refresh tokens are stored encrypted in PostgreSQL, keyed by
`provider + hop1_issuer + hop1_subject`. Provide a DSN via `TOKEN_STORE_DSN`.

- **Compose:** the bundled `token-store` service is seeded from
  `servers/google-workspace/config/oauth-schema.sql`; the default DSN
  `postgres://mcp:mcp@token-store:5432/mcp` works out of the box.
- **Kubernetes:** point `TOKEN_STORE_DSN` (inside the provider Secret) at your
  database and enable `oauthMigrations` with a `secretKeyRef` to a Secret key
  holding the DSN. The pre-install/pre-upgrade hook applies the schema under an
  advisory lock. When the database uses a private CA, configure
  `postgresql.caBundle` with exactly one existing `ConfigMap` or `Secret` key.

### Optional backends

- **GitHub MCP:** enable `githubWrapper` and `githubMcp`, add the `github-mcp`
  backend, and register a GitHub OAuth app with callback
  `https://<your-mcp-host>/oauth/github/callback`. The shipped wrapper and upstream toolset defaults
  are aligned. If you override `githubMcp.env.GITHUB_TOOLSETS`, set the same selection in the
  existing `githubWrapper.env.GITHUB_MCP_TOOLSETS` value. Start from
  [`deploy/k8s/examples/values-github-mcp.example.yaml`](../deploy/k8s/examples/values-github-mcp.example.yaml).
- **Google Workspace tool policy:** enable `googleWorkspace.policy` with inline
  YAML. See
  [`deploy/k8s/examples/values-google-policy.example.yaml`](../deploy/k8s/examples/values-google-policy.example.yaml).
- **External governing platform:** configure its workload-token issuer,
  introspection Secret reference, shared policy endpoint, private lifecycle
  callers, and GitHub return origins using
  [`docs/external-platform-issuer.md`](external-platform-issuer.md).
- **Full production bundle:** see
  [`deploy/k8s/examples/values-production-bundle.example.yaml`](../deploy/k8s/examples/values-production-bundle.example.yaml).

---

## 3. Use

Point any MCP client that speaks Streamable HTTP at the public endpoint and send
a HOP-1 bearer token on every request:

```http
POST https://mcp.example.com/mcp
Authorization: Bearer <hop1-user-token>
Content-Type: application/json
Mcp-Protocol-Version: 2025-06-18
```

Clients that support MCP OAuth protected-resource discovery can obtain the token
themselves from the advertised metadata at
`/.well-known/oauth-protected-resource/mcp`. Others should be handed a token
minted by your identity provider for the MCP audience.

### Connect on first use

Before a provider is connected, its wrapper advertises **only** its connection
helpers on `tools/list`:

```text
google_oauth_status   google_oauth_start
github_oauth_status   github_oauth_start   # when the GitHub backend is enabled
```

1. Call `google_oauth_status` to check whether the caller is connected and which
   scopes are missing.
2. Call `google_oauth_start` to get an `authorizationUrl`. Open it, approve the
   Google consent screen, and return.
3. Call a Google Workspace data tool from the catalog that was already advertised.
   Before consent it returns structured `provider_oauth_required`; after consent
   the same cached tool handle succeeds without another `tools/list`, MCP session,
   or reconnect. The catalog includes curated `google_*` tools, generated `gws_*`
   tools, and the `google_workspace_gws` passthrough.

Provider grants are never inferred from the HOP-1 login: every provider is
gated by its own consent. Use the same stable HOP-1 subject for connect, status,
and later tool calls. Headless clients and portals should use the canonical
`/connections/{provider}/authorize|status|refresh|disconnect` HTTP routes with
a trusted HOP-1 token. The older private
`/oauth/{provider}/{start,status,refresh,disconnect}` aliases remain supported
through the complete 0.6.x release line; their earliest possible removal is
0.7.0, announced in the preceding minor release notes. Provider callbacks are
separate registered return endpoints, not compatibility aliases. See
[`provider-connection-flows.md`](provider-connection-flows.md) and the
[`client-integration-runbook.md`](client-integration-runbook.md).
