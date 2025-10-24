# Install Vault with ACME, OIDC, and Versity S3 Integration

## 1. Prerequisites

0. Clone this repository and initialize the environment using the scripts in the repository. You may want to modify the values in `install.env` before exporting the variables.

```bash
git clone https://github.com/davidallendj/vault-install
cd vault-install
source bin/funcs.sh
export_env # export$(cat install.env)
```

> [!TIP] 
> This should set a couple of environment variables needed later on in this guide. Confirm that they are set using `printenv`.
> 
> ```bash
> printenv | grep VAULT
> ```

1. Download and [install vault](https://developer.hashicorp.com/vault/install) binary. This guide assumes that the `vault` binary is installed in the `$repo/bin` directory.

2. Create certificates using OpenSSL. Self-signed certificates are generated and used for this guide, but you can use your CA in production.

```bash
openssl req -nodes -x509 -days 365 -keyout certs/server.key -out certs/server.crt -config certs/cert.conf
```

Adjust the command and flags above as needed. You may need to update the `certs/cert.conf` with the appropriate domain name(s).

3. Initialize vault and save the keys and root token somewhere secure. You should have 5 keys since `-key-shares=5` and will need these to unseal the vault and for logging in. You may also want to make sure that you have the `VAULT_ADDR` environment variable set.

```bash
vault operator init -key-shares=5 -key-threshold=3
``` 

> [!TIP] 
> You may also want to set the `VAULT_TOKEN` environment variable to the root token here.

4. Unseal and log into vault using the keys generated above and login. You'll need to do these 3 times since the vault was initialized with `-key-threshold=3`

```bash
# do this 3 times with 3 of the 5 generated keys
vault operator unseal

# use the generated root token here
vault login
```

## 2. Set up PKI and ACME service

This section covers how to set up the PKI mount and ACME service. Make sure that you have the `BASE_DOMAIN`, `PKI_MOUNT`, and `ACME_ROLE` environment variables set before proceeding. You may need to add the `-tls-skip-verify` flag if no valid certificate is provided via the `VAULT_CERT` environment variable. However, this is not guaranteed to work without valid certificates.

1. Enable PKI. Make sure that you ahve the `BASE_DOMAIN`, 

```bash
vault secrets enable -path="$PKI_MOUNT" pki
```

2. Generate a root - import your real CA in production

```bash
vault write $PKI_MOUNT/root/generate/internal common_name="${BASE_DOMAIN} Root CA" ttl=87600h
```

3. Set the CA/CRL URLs so clients can fetch chain & revocation.

```bash
vault write $PKI_MOUNT/config/urls \
  issuing_certificates="${VAULT_ADDR}/v1/${PKI_MOUNT}/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/${PKI_MOUNT}/crl"
```

4. Set role used by ACME to issue leaf certs for your domain.

```bash
vault write $PKI_MOUNT/roles/$ACME_ROLE \
  allowed_domains="$BASE_DOMAIN" allow_bare_domains=true allow_subdomains=true max_ttl="720h"
```

5. Expose ACME directory and optionally require EAB (recommended).

```bash
vault write $PKI_MOUNT/config/cluster path="${VAULT_ADDR}/v1/${PKI_MOUNT}"
vault write $PKI_MOUNT/config/acme enabled=true allowed_roles="$ACME_ROLE" eab_policy="always-required"
```

6. Create an EAB pair (kid + hmac_key) for your ACME client.

```bash
vault write -format=json $PKI_MOUNT/acme/eab role="$ACME_ROLE"
```

The ACME directory path is `$VAULT_ADDR/v1/$PKI_MOUNT/acme/directory`.

## 3. Set up OIDC Provider

This section covers configuring vault as an OIDC provider. Confirm that the `OIDC_PROVIDER`, `OIDC_KEY`, `OIDC_ROLE`, and `OIDC_TTL` variables are set before proceeding.

1. Create a signing key.

```bash
vault write identity/oidc/key/$OIDC_KEY algorithm=RS256
```

2. Set the OIDC Provider.

```bash
vault write identity/oidc/provider/$OIDC_PROVIDER issuer="${VAULT_ADDR}"
```

3. Add the `openchami-role` client ID to the `openchami-signer`.

> [!NOTE]
> You can check the client IDs with the following command.
> 
> ```bash
> vault read identity/oidc/key/openchami-signer
>
> Key                   Value
> ---                   -----
> algorithm             RS256
> allowed_client_ids    []
> rotation_period       24h
> verification_ttl      24h
> ```

Copy the `client_id`.

```bash
vault read identity/oidc/role/openchami-role
Key          Value
---          -----
client_id    clvNzKGgeAKZuCQLE3XapM7pRu
key          openchami-signer
template     {
  "tenant": "lanl",
  "scope": ["s3:read", "s3:write"]
}
ttl          15m
```

Add it to the list of `allowed_client_ids`.

```bash
vault write identity/oidc/key/openchami-signer allowed_client_ids="clvNzKGgeAKZuCQLE3XapM7pRu"                               
Success! Data written to: identity/oidc/key/openchami-signer
```

4. Set up role with custom claims ("aud" not allowed)

```bash
cat > /tmp/claims.json <<'JSON'
{
  "aud": ["openchami"],
  "tenant": "lanl",
  "scope": ["s3:read", "s3:write"]
}
JSON
```

5. Update claims for OIDC provider

```bash
vault write identity/oidc/role/$OIDC_ROLE key="$OIDC_KEY" \
  ttl="$OIDC_TTL" template=@/tmp/claims.json
```

6. Confirm the discovery and JWKS endpoints are reachable.

```bash
echo "Discovery: ${VAULT_ADDR}/v1/identity/oidc/provider/${OIDC_PROVIDER}/.well-known/openid-configuration"
echo "JWKS:      ${VAULT_ADDR}/v1/identity/oidc/provider/${OIDC_PROVIDER}/.well-known/keys"
```

7. Issue a token reading the `OIDC_ROLE`.

```bash
vault read identity/oidc/token/$OIDC_ROLE
```

## 4. Set up the Versity S3 gateway

This section covers setting up Versity integration with vault. Make sure that the `VERSITY_KV`, `VERSITY_POLICY`, and `VERSITY_APPROLE` environment variables are set before proceeding.

1. Enable kv-v2 at a dedicated path.

```bash
vault secrets enable -path="$VERSITY_KV" -version=2 kv
```

2. Grant versitygw CRUD on that mount.

```bash
cat > /tmp/versity.hcl <<HCL
path "$VERSITY_KV/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
HCL
vault policy write "$VERSITY_POLICY" /tmp/versity.hcl
```

3. Enable AppRole and create a role bound to that policy.

```bash
vault auth enable approle || true
vault write auth/approle/role/$VERSITY_APPROLE \
  token_policies="$VERSITY_POLICY" token_ttl="24h" token_max_ttl="0"
```

4. Retrieve `ROLE_ID` and `SECRET_ID` for the gateway.

```bash
vault read -format=json auth/approle/role/$VERSITY_APPROLE/role-id
vault write -format=json -f auth/approle/role/$VERSITY_APPROLE/secret-id
```
