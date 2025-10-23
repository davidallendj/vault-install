PATH=$PATH:/home/allend/vault-install/bin
generate_certs() {
	openssl req -nodes -x509 -days 365 -keyout certs/server.key -out certs/server.crt -config certs/cert.conf
}

start_vault() {
	vault server -config config/vault.hcl
}

init_vault() {
	vault operator init -key-shares=5 -key-threshold=3 | head -n 6 > keys/vault.keys
	export $(cat keys/vault.keys | cut -d " " -f 4)
}

export_env() {
	export $(cat openchami.env)
}

help_me() {
	cat README.md
}
