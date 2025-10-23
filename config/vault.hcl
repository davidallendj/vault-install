# -------- Storage (Integrated / Raft)
storage "raft" {
  path    = "/opt/vault/data"
  # path    = "./data"
  node_id = "nid001"
  # For multi-node, add retry_join blocks pointing at peers
  # retry_join { leader_api_addr = "https://vault-2.example.com:8200" }
}

# -------- Listener (TLS)
listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "./certs/server.crt"
  tls_key_file    = "./certs/server.key"
}

# -------- API/Cluster addresses (public names clients use)
api_addr     = "https://redondo.usrc:8200"
cluster_addr = "https://redondo.usrc:8201"

# -------- Telemetry (optional)
disable_mlock = true   # set to false if your OS allows mlock without issues
ui            = true

allowed_roles="web"
