# Install Vault with ACME, OIDC, and Versity S3 Integration

## Prerequisites

0. Clone this repository and initialize the environment using the scripts in the repository.

```bash
git clone https://github.com/davidallendj/vault-install
cd vault-install
source bin/funcs.sh
export $(cat install.env)
```

1. Download and [install vault](https://developer.hashicorp.com/vault/install) binary. This guide assumes that the `vault` binary is installed in the `$repo/bin` directory.
2. Create certificates using OpenSSL. Self-signed certificates are generated and used for this guide, but you can use your CA in production.

```bash
openssl req -nodes -x509 -days 365 -keyout certs/server.key -out certs/server.crt -config certs/cert.conf
```

Adjust the command and flags above as needed.

3. Initialize vault and save the keys and root token somewhere secure. You should have 5 keys since `-key-shares=5` and will need these to unseal the vault and for logging in.

```bash
vault operator init -key-shares=5 -key-threshold=3
``` 

4. Unseal and log into vault using the keys generated above and login. You'll need to do these 3 times since the vault was initialized with `-key-threshold=3`

```bash
# do this 3 times with 3 of the 5 generated keys
vault operator unseal

# use the generated root token here
vault login
```

## Set up PKI and ACME service

1. Enable PKI `vault secrets enable -tls-skip-verify -path="$PKI_MOUNT" pki`
2. Generate a root - import your real CA in production

```bash
vault write -tls-skip-verify $PKI_MOUNT/root/generate/internal common_name="${BASE_DOMAIN} Root CA" ttl=87600h
```

3. 

## Set up OIDC Provider

1. Create a signing key

```bash
vault write identity/oidc/key/$OIDC_KEY algorithm=RS256
```

2. Set up OIDC Provider 

```bash
vault write identity/oidc/provider/$OIDC_PROVIDER issuer="${VAULT_ADDR}"
```

3. Add the `openchami-role` client ID to the `openchami-signer`

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

Get the client ID.

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

Update claims for OIDC provider

```bash
vault write identity/oidc/role/$OIDC_ROLE key="$OIDC_KEY" \
  ttl="$OIDC_TTL" template=@/tmp/claims.json
```

5. Confirm the discovery and JWKS endpoints are functional.

```bash
echo "Discovery: ${VAULT_ADDR}/v1/identity/oidc/provider/${OIDC_PROVIDER}/.well-known/openid-configuration"
echo "JWKS:      ${VAULT_ADDR}/v1/identity/oidc/provider/${OIDC_PROVIDER}/.well-known/keys"
```

6. Issue a token reading the `OIDC_ROLE`.

```bash
vault read identity/oidc/token/$OIDC_ROLE
```

## Set up the Versity S3 gateway


