#!/bin/sh
set -eu

CONFIG_URI="${SPRING_CLOUD_CONFIG_URI:-http://config-server:8888}"
EUREKA_URL="${EUREKA_CLIENT_SERVICEURL_DEFAULTZONE:-http://discovery:8761/eureka/}"
MONGO_HOST="$(echo ${SPRING_DATA_MONGODB_URI:-mongodb://mongo:27017} | sed -E 's#mongodb://([^/:]+).*#\\1#')"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
CLIENT_ID="${BOOKING_CLIENT_ID:-booking-service}"
CLIENT_SECRET_FILE="${BOOKING_CLIENT_SECRET_FILE:-/run/secrets/booking_client_secret}"

# read secret into variable (not echoed)
if [ -f "${CLIENT_SECRET_FILE}" ]; then
  CLIENT_SECRET="$(cat "${CLIENT_SECRET_FILE}")"
else
  echo "Client secret file ${CLIENT_SECRET_FILE} not found" >&2
  exit 1
fi

echo "Waiting for Config Server at ${CONFIG_URI}..."
until curl -sSf "${CONFIG_URI}/actuator/health" >/dev/null 2>&1; do
  sleep 2
done

echo "Waiting for Eureka at ${EUREKA_URL}..."
until curl -sSf "${EUREKA_URL}" >/dev/null 2>&1; do
  sleep 2
done

echo "Waiting for MongoDB at ${MONGO_HOST}:27017..."
until nc -z "${MONGO_HOST}" 27017 >/dev/null 2>&1; do
  sleep 2
done

echo "Waiting for Keycloak token endpoint..."
until curl -sSf "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM:-cinema}/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  >/dev/null 2>&1; do
  sleep 2
done

echo "All dependencies available — continuing."
