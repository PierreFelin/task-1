#!/bin/sh
set -eu

CONFIG_URI="${SPRING_CLOUD_CONFIG_URI:-http://config-server:8888}"
EUREKA_URL="${EUREKA_CLIENT_SERVICEURL_DEFAULTZONE:-http://discovery:8761/eureka/}"
MONGO_HOST="$(echo ${SPRING_DATA_MONGODB_URI:-mongodb://mongo:27017} | sed -E 's#mongodb://([^/:]+).*#\\1#')"

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

echo "All dependencies available — continuing."
