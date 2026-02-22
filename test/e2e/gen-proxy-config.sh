#!/bin/bash -e

# This script generates a kubeconfig that points to the Nginx proxy (localhost:9443)
# and uses an OIDC token fetched from Dex for authentication.

OUTPUT_FILE="${1:-proxy.kubeconfig}"
# user2@konflux.dev has konflux-admin-user-actions role in user-ns2 (the E2E
# test namespace), matching the E2E_APPLICATIONS_NAMESPACE used in run-e2e.sh.
USERNAME="user2@konflux.dev"
PASSWORD="password"
PROXY_URL="https://localhost:9443"

# 1. Fetch the proxy CA certificate (issued by cert-manager ui-ca-issuer)
echo "Fetching proxy CA certificate..." >&2
CA_CERT_B64=$(kubectl get secret -n konflux-ui ui-ca -o jsonpath='{.data.tls\.crt}')
if [ -z "$CA_CERT_B64" ]; then
    echo "Error: Could not find ui-ca secret in konflux-ui namespace." >&2
    exit 1
fi

# Write CA cert to a temporary file for curl to use
CA_CERT_FILE=$(mktemp)
echo "$CA_CERT_B64" | base64 -d > "$CA_CERT_FILE"
trap 'rm -f "$CA_CERT_FILE"' EXIT

# 2. Fetch OAuth2 Client Secret
echo "Fetching OAuth2 client secret..." >&2
CLIENT_SECRET=$(kubectl get secret -n konflux-ui oauth2-proxy-client-secret -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d)
if [ -z "$CLIENT_SECRET" ]; then
    CLIENT_SECRET=$(kubectl get secret -n dex oauth2-proxy-client-secret -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d)
fi

if [ -z "$CLIENT_SECRET" ]; then
    echo "Error: Could not find oauth2-proxy-client-secret in konflux-ui or dex namespaces." >&2
    exit 1
fi

# 3. Fetch ID Token from Dex
echo "Fetching ID token from Dex..." >&2
TOKEN_RESPONSE=$(curl -s --cacert "$CA_CERT_FILE" -u "oauth2-proxy:$CLIENT_SECRET" \
    -d "grant_type=password&username=$USERNAME&password=$PASSWORD&scope=openid profile email" \
    "$PROXY_URL/idp/token")

# Extract id_token using grep/sed (to avoid dependency on jq if possible, though jq is preferred)
ID_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"id_token":"[^"]*' | sed 's/"id_token":"//')

if [ -z "$ID_TOKEN" ]; then
    echo "Error: Failed to obtain ID token. Response: $TOKEN_RESPONSE" >&2
    exit 1
fi

# 4. Generate Kubeconfig
echo "Generating kubeconfig at $OUTPUT_FILE..." >&2
cat > "$OUTPUT_FILE" <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: $CA_CERT_B64
    server: $PROXY_URL/api/k8s
  name: konflux-proxy
contexts:
- context:
    cluster: konflux-proxy
    user: konflux-user
  name: konflux-proxy
current-context: konflux-proxy
kind: Config
preferences: {}
users:
- name: konflux-user
  user:
    token: $ID_TOKEN
EOF

echo "Success!" >&2
