#!/bin/sh
set -eu

KC_URL="http://keycloak:8080"
ADMIN_USER="admin"
ADMIN_PASS="admin"
REALM="cinema"
CLIENT_ID="booking-service"
ROLE_NAME="MOVIE_CHECK"

echo "Waiting for Keycloak to become available..."
# wait for Keycloak token endpoint (use master realm admin-cli)
until curl -sSf "${KC_URL}/realms/master/.well-known/openid-configuration" > /dev/null 2>&1; do
  sleep 1
done

echo "Getting admin token..."
TOKEN=$(curl -s -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASS}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Failed to obtain admin token" >&2
  exit 1
fi

echo "Finding client internal id for ${CLIENT_ID}..."
CLIENT_UUID=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id')

if [ -z "$CLIENT_UUID" ] || [ "$CLIENT_UUID" = "null" ]; then
  echo "Cannot find client ${CLIENT_ID}" >&2
  exit 1
fi

echo "Getting service-account user id for client ${CLIENT_ID}..."
SERVICE_USER_ID=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/service-account-user" | jq -r '.id')

if [ -z "$SERVICE_USER_ID" ] || [ "$SERVICE_USER_ID" = "null" ]; then
  echo "Service account user not found (is serviceAccountsEnabled true on client?)" >&2
  exit 1
fi

echo "Getting role representation for ${ROLE_NAME}..."
ROLE_JSON=$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "${KC_URL}/admin/realms/${REALM}/roles/${ROLE_NAME}")

if [ -z "$ROLE_JSON" ] || [ "$ROLE_JSON" = "null" ]; then
  echo "Role ${ROLE_NAME} not found" >&2
  exit 1
fi

echo "Assigning realm role ${ROLE_NAME} to service account user..."
# POST expects an array of role objects
curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "[${ROLE_JSON}]" \
  "${KC_URL}/admin/realms/${REALM}/users/${SERVICE_USER_ID}/role-mappings/realm"

echo "Done. Assigned ${ROLE_NAME} to booking-service's service account."
