#!/bin/bash

set -e

# Uso: ./setup-auto.sh <dominio> <email> <user> <senha> [traefik_sub] [portainer_sub]
# Exemplo: ./setup-auto.sh meusite.com.br admin@email.com admin minhasenha traefik portainer

DOMAIN="$1"
EMAIL="$2"
TRAEFIK_USER="$3"
TRAEFIK_PASS="$4"
TRAEFIK_SUB="${5:-traefik}"
PORTAINER_SUB="${6:-portainer}"

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ] || [ -z "$TRAEFIK_USER" ] || [ -z "$TRAEFIK_PASS" ]; then
  echo "Uso: $0 <dominio> <email> <user> <senha> [traefik_sub] [portainer_sub]"
  echo "Exemplo: $0 meusite.com.br admin@email.com admin minhasenha"
  exit 1
fi

TRAEFIK_DOMAIN="${TRAEFIK_SUB}.${DOMAIN}"
PORTAINER_DOMAIN="${PORTAINER_SUB}.${DOMAIN}"

echo "=== Setup Traefik + Portainer ==="
echo "Traefik: https://${TRAEFIK_DOMAIN}"
echo "Portainer: https://${PORTAINER_DOMAIN}"

# Instalar htpasswd se não existir
apt-get update -qq && apt-get install -y -qq apache2-utils > /dev/null 2>&1 || true

# Gerar hash
HASHED_PASS=$(echo "$TRAEFIK_PASS" | htpasswd -niB "$TRAEFIK_USER" | sed 's/\$/\$\$/g')

# Criar estrutura em /web
mkdir -p /web/traefik /web/portainer/data
cd /web

touch traefik/acme.json && chmod 600 traefik/acme.json
docker network create web 2>/dev/null || true

# traefik.toml
cat > traefik/traefik.toml << EOF
[entryPoints]
  [entryPoints.web]
    address = ":80"
    [entryPoints.web.http.redirections.entryPoint]
      to = "websecure"
      scheme = "https"
  [entryPoints.websecure]
    address = ":443"

[log]
  level = "WARN"

[api]
  dashboard = true

[certificatesResolvers.lets-encrypt.acme]
  email = "${EMAIL}"
  storage = "acme.json"
  [certificatesResolvers.lets-encrypt.acme.httpChallenge]
    entryPoint = "web"

[providers.docker]
  watch = true
  network = "web"

[providers.file]
  filename = "traefik_dynamic.toml"
EOF

# traefik_dynamic.toml
cat > traefik/traefik_dynamic.toml << EOF
[http.middlewares.simpleAuth.basicAuth]
  users = ["${HASHED_PASS}"]

[http.routers.api]
  rule = "Host(\`${TRAEFIK_DOMAIN}\`)"
  entrypoints = ["websecure"]
  middlewares = ["simpleAuth"]
  service = "api@internal"
  [http.routers.api.tls]
    certResolver = "lets-encrypt"
EOF

# compose.yml
cat > compose.yml << EOF
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    restart: always
    networks: [web]
    ports: ["80:80", "443:443"]
    environment: [TZ=America/Sao_Paulo]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./traefik/traefik.toml:/traefik.toml
      - ./traefik/traefik_dynamic.toml:/traefik_dynamic.toml
      - ./traefik/acme.json:/acme.json

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    networks: [web]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer/data:/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`${PORTAINER_DOMAIN}\`)"
      - "traefik.http.routers.portainer.tls=true"
      - "traefik.http.routers.portainer.tls.certresolver=lets-encrypt"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"

networks:
  web:
    external: true
EOF

docker compose up -d

echo "=== Concluído! ==="
echo "Diretório: /web"
echo "Traefik: https://${TRAEFIK_DOMAIN}"
echo "Portainer: https://${PORTAINER_DOMAIN}"
