#!/usr/bin/env bash
set -euo pipefail

############################################
# Configuration (edit or set via env)
############################################
: "${VAULT_ADDR:?Set VAULT_ADDR (e.g., https://vault.example.com:8200)}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN with admin permissions}"

# ACME / PKI settings
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"           # Your DNS zone for ACME
ACME_PKI_PATH="${ACME_PKI_PATH:-pki}"               # Mount for PKI engine
ACME_ROLE_NAME="${ACME_ROLE_NAME:-web}"             # PKI role name for leaf certs
ACME_REQUIRE_EAB="${ACME_REQUIRE_EAB:-true}"        # true|false (recommended: true)

# OIDC (JWT) settings
OIDC_PROVIDER_NAME="${OIDC_PROVIDER_NAME:-openchami}"   # public OIDC provider name
OIDC_KEY_NAME="${OIDC_KEY_NAME:-chami-signer}"          # signer key name
OIDC_ROLE_NAME="${OIDC_ROLE_NAME:-openchami-role}"      # role that mints JWTs
OIDC_TOKEN_TTL="${OIDC_TOKEN_TTL:-15m}"                 # access token TTL
OIDC_AUDIENCE="${OIDC_AUDIENCE:-openchami}"             # aud claim
OIDC_TENANT_CLAIM="${OIDC_TENANT_CLAIM:-lanl}"          # example custom claim
OIDC_SCOPE_CLAIM="${OIDC_SCOPE_CLAIM:-s3:read}"         # example custom claim

# Versity IAM settings
VERSITY_IAM_PATH="${VERSITY_IAM_PATH:-versity-iam}"     # kv-v2 mount (e.g. versity-iam/)
VERSITY_POLICY_NAME="${VERSITY_POLICY_NAME:-versity-iam}"
VERSITY_APPROLE_NAME="${VERSITY_APPROLE_NAME:-versitygw}"
VERSITY_TOKEN_TTL="${VERSITY_TOKEN_TTL:-24h}"

# Utilities
JQ="${JQ:-jq}" # optional

echo "==> Using VAULT_ADDR=$VAULT_ADDR"
vault status >/dev/null

############################################
# 1) PKI as ACME Server
############################################
echo "==> Enabling PKI @ $ACME_PKI_PATH (idempotent)"
if ! vault secrets list -format=json | grep -q "\"$ACME_PKI_PATH/\""; then
  vault secrets enable -path="$ACME_PKI_PATH" pki
else
  echo "    PKI already enabled at $ACME_PKI_PATH"
fi

# Generate a root (for demo). In production, import your real root or an intermediate.
if ! vault read -format=json "$ACME_PKI_PATH/ca" >/dev/null 2>&1; then
  echo "==> Generating self-signed Root CA for demo (use proper CA in prod)"
  vault write "$ACME_PKI_PATH/root/generate/internal" \
    common_name="${BASE_DOMAIN} Root CA" \
    ttl=87600h >/dev/null
else
  echo "    CA already present"
fi

# Configure URLs so ACME clients can fetch CA and CRL
echo "==> Configuring PKI URLs"
vault write "$ACME_PKI_PATH/config/urls" \
  issuing_certificates="${VAULT_ADDR}/v1/${ACME_PKI_PATH}/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/${ACME_PKI_PATH}/crl" >/dev/null

# Create a role used by ACME to issue leaf certs
echo "==> Ensuring PKI role '$ACME_ROLE_NAME'"
vault write "$ACME_PKI_PATH/roles/$ACME_ROLE_NAME" \
  allowed_domains="$BASE_DOMAIN" \
  allow_bare_domains=true \
  allow_subdomains=true \
  max_ttl="720h" >/dev/null

# Enable ACME directory + (optional) EAB requirement
echo "==> Enabling ACME"
vault write "$ACME_PKI_PATH/config/cluster" path="${VAULT_ADDR}/v1/${ACME_PKI_PATH}" >/dev/null
vault write "$ACME_PKI_PATH/config/acme" \
  enabled=true \
  allowed_roles="$ACME_ROLE_NAME" \
  eab_policy="$([ "${ACME_REQUIRE_EAB}" = "true" ] && echo always-required || echo not-required)" >/dev/null

# Create an EAB credential for clients (print once)
echo "==> Creating an EAB credential for ACME clients (role=$ACME_ROLE_NAME)"
EAB_JSON=$(vault write -format=json "$ACME_PKI_PATH/acme/eab" role="$ACME_ROLE_NAME")
echo "    ACME Directory: ${VAULT_ADDR}/v1/${ACME_PKI_PATH}/acme/directory"
if command -v "$JQ" >/dev/null 2>&1; then
  echo "$EAB_JSON" | $JQ -r '.data | {kid, hmac_key}'
else
  echo "$EAB_JSON"
  echo "    (Install jq for prettier output)"
fi

############################################
# 2) OIDC Provider for JWTs with custom claims
############################################
# Create a signing key and provider
echo "==> Configuring OIDC provider '$OIDC_PROVIDER_NAME' with key '$OIDC_KEY_NAME'"
if ! vault read "identity/oidc/key/$OIDC_KEY_NAME" >/dev/null 2>&1; then
  vault write "identity/oidc/key/$OIDC_KEY_NAME" algorithm="RS256" >/dev/null
else
  echo "    OIDC key already exists"
fi

# The issuer URL should be stable and externally reachable for discovery.
# It will expose: /.well-known/openid-configuration and /jwks endpoints.
PROVIDER_ISSUER="${VAULT_ADDR}/v1/identity/oidc/provider/${OIDC_PROVIDER_NAME}"
if ! vault read "identity/oidc/provider/${OIDC_PROVIDER_NAME}" >/dev/null 2>&1; then
  vault write "identity/oidc/provider/${OIDC_PROVIDER_NAME}" issuer="$PROVIDER_ISSUER" >/dev/null
else
  echo "    OIDC provider already exists"
fi

# Define a role that issues tokens with custom claims using a JSON template.
# The template supports Go templating with a limited context. For simple setups,
# static custom claims are fine; you can later reference identity metadata.
OIDC_TEMPLATE=$(cat <<'JSON'
{
  "aud": ["__AUDIENCE__"],
  "tenant": "__TENANT__",
  "scope": ["__SCOPE__"],
  "custom_note": "issued-by-vault"
}
JSON
)
OIDC_TEMPLATE="${OIDC_TEMPLATE/__AUDIENCE__/$OIDC_AUDIENCE}"
OIDC_TEMPLATE="${OIDC_TEMPLATE/__TENANT__/$OIDC_TENANT_CLAIM}"
OIDC_TEMPLATE="${OIDC_TEMPLATE/__SCOPE__/$OIDC_SCOPE_CLAIM}"

# Upsert role
echo "==> Creating OIDC role '$OIDC_ROLE_NAME'"
vault write "identity/oidc/role/${OIDC_ROLE_NAME}" \
  key="$OIDC_KEY_NAME" \
  template="$OIDC_TEMPLATE" \
  ttl="$OIDC_TOKEN_TTL" >/dev/null

echo "    OIDC Discovery URL: ${PROVIDER_ISSUER}/.well-known/openid-configuration"
echo "    JWKS: ${PROVIDER_ISSUER}/.well-known/keys"
echo "    To mint a token (example): vault read identity/oidc/token/${OIDC_ROLE_NAME}"

############################################
# 3) VersityGW IAM backend (kv-v2 + AppRole)
############################################
echo "==> Enabling kv-v2 for Versity IAM @ ${VERSITY_IAM_PATH}"
if ! vault secrets list -format=json | grep -q "\"${VERSITY_IAM_PATH}/\""; then
  vault secrets enable -path="$VERSITY_IAM_PATH" -version=2 kv
else
  echo "    kv-v2 already enabled at ${VERSITY_IAM_PATH}"
fi

# Policy granting versitygw full CRUD on IAM records under that path
echo "==> Writing policy '${VERSITY_POLICY_NAME}'"
cat > /tmp/versity-iam-policy.hcl <<POL
path "${VERSITY_IAM_PATH}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
POL
vault policy write "$VERSITY_POLICY_NAME" /tmp/versity-iam-policy.hcl >/dev/null
rm -f /tmp/versity-iam-policy.hcl

# AppRole for the gateway
echo "==> Enabling AppRole (if not already)"
vault auth enable approle >/dev/null 2>&1 || true

echo "==> Creating AppRole '${VERSITY_APPROLE_NAME}' for versitygw"
vault write "auth/approle/role/${VERSITY_APPROLE_NAME}" \
  token_policies="${VERSITY_POLICY_NAME}" \
  token_ttl="${VERSITY_TOKEN_TTL}" \
  token_max_ttl=0 \
  secret_id_ttl=0 \
  secret_id_num_uses=0 >/dev/null

ROLE_ID=$(vault read -format=json "auth/approle/role/${VERSITY_APPROLE_NAME}/role-id" | ${JQ:-cat} -r '.data.role_id')
SECRET_ID=$(vault write -format=json -f "auth/approle/role/${VERSITY_APPROLE_NAME}/secret-id" | ${JQ:-cat} -r '.data.secret_id')
echo "    AppRole ROLE_ID:   ${ROLE_ID}"
echo "    AppRole SECRET_ID: ${SECRET_ID}"

############################################
# Output helpful snippets
############################################
cat <<SNIPS

=============================================================
ACME Client Configuration
=============================================================
Directory: ${VAULT_ADDR}/v1/${ACME_PKI_PATH}/acme/directory
(Use the EAB kid/hmac_key printed above with certbot, acme.sh, lego, cert-manager, Caddy, etc.)

Examples:
  # certbot (using EAB)
  certbot \
    --server ${VAULT_ADDR}/v1/${ACME_PKI_PATH}/acme/directory \
    --eab-kid <kid> --eab-hmac-key <hmac_key> \
    -d host.${BASE_DOMAIN} --agree-tos --email you@${BASE_DOMAIN} \
    --manual --preferred-challenges dns

=============================================================
OIDC (JWT) Usage
=============================================================
Discovery URL:
  ${PROVIDER_ISSUER}/.well-known/openid-configuration

Get a token (as a Vault-authenticated entity):
  vault read identity/oidc/token/${OIDC_ROLE_NAME}

Token will include custom claims like:
  { "aud": ["${OIDC_AUDIENCE}"], "tenant": "${OIDC_TENANT_CLAIM}", "scope": ["${OIDC_SCOPE_CLAIM}"], ... }

=============================================================
Versity S3 Gateway (versitygw) Vault IAM Settings
=============================================================
# Point the gateway at Vault kv-v2 path: ${VERSITY_IAM_PATH}/
# Use AppRole auth with the ROLE_ID and SECRET_ID above.

# Example env (adjust to your versitygw flags or config file):
VERSITYGW_VAULT_ADDR="${VAULT_ADDR}"
VERSITYGW_VAULT_NAMESPACE=""                 # if using namespaces, set accordingly
VERSITYGW_VAULT_IAM_PATH="${VERSITY_IAM_PATH}"  # kv-v2 mount path
VERSITYGW_VAULT_AUTH="approle"
VERSITYGW_VAULT_ROLE_ID="${ROLE_ID}"
VERSITYGW_VAULT_SECRET_ID="${SECRET_ID}"

# IAM user records will be stored/read under: ${VERSITY_IAM_PATH}/data/<something>
# (The gateway will handle the exact key structure; you just provide the mount path and auth.)
=============================================================

All done ✅
SNIPS
