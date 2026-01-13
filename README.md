1) Overview — what you will accomplish

You will end up able to:

Build images for Keycloak (with the cinema realm baked in), Config Server (with embedded config), Discovery, Gateway, Movie and Booking services, and optionally a Mongo image with initial data.

Transport images to another machine (PC B) via registry (recommended) or tar file.

Start containers on PC B using podman (no docker-compose), in the correct order, with proper secrets, volumes and network.

Verify the system.

2) Design decisions & important principles (short)

Build vs runtime: Builds create images that include files you COPY in Dockerfile. They do not include volumes or files you mounted at runtime unless you purposely COPY them into the image.

Secrets: don’t bake production secrets into images. For a portable dev/demo you can bake them but know this is insecure. Better: provide the secret as a file on PC B and mount it or use Podman secrets.

Order matters at runtime (Mongo → Keycloak → Config → Discovery → movie/booking → gateway). Use entrypoint wait scripts to avoid race conditions.

Architecture: if PC A is amd64 and PC B is arm64, images must be built multi-arch or rebuilt on PC B.

3) Make images self-contained (recommended for portability)

Below are the minimal Dockerfiles / scripts to create self-contained images so PC B needs only to pull/load images and supply minimal runtime secrets/files.

3.1 Keycloak image (bake realm + init script)

Files you need locally before building:

keycloak/realms/cinema-realm.json (the realm import JSON; contains client secret booking-secret-please-change unless you change it)

keycloak/init/assign-service-account-role.sh (the admin script that assigns MOVIE_CHECK to the booking-service service account)

keycloak/Dockerfile

keycloak/start-and-init.sh

keycloak/Dockerfile

FROM quay.io/keycloak/keycloak:latest

# copy realm import and init scripts into the image
COPY realms /opt/keycloak/data/import
COPY init /opt/keycloak-init
COPY start-and-init.sh /opt/keycloak/start-and-init.sh

RUN chmod +x /opt/keycloak-init/*.sh /opt/keycloak/start-and-init.sh

ENTRYPOINT ["/opt/keycloak/start-and-init.sh"]


keycloak/start-and-init.sh

#!/bin/sh
set -eu

# Start Keycloak in background
/opt/keycloak/bin/kc.sh start-dev --import-realm & 
KC_PID=$!

# Wait for KC to be reachable
until curl -sSf http://localhost:8080/realms/master/.well-known/openid-configuration >/dev/null 2>&1; do
  sleep 1
done

# Run admin-init (uses KEYCLOAK_ADMIN and KEYCLOAK_ADMIN_PASSWORD env vars)
sh /opt/keycloak-init/assign-service-account-role.sh || {
  echo "Warning: assign-service-account-role.sh failed (see logs)"
}

# Wait so the container doesn't exit
wait $KC_PID


Security note: The realm JSON will be embedded in image layers. If it contains client secrets, they are present in the image. OK for dev but not for production.

3.2 Config Server (embed config repo into image)

If you don’t want a Git dependency on PC B, build config server with configs embedded.

File layout: config-repo/ contains movie-service.yml, booking-service.yml, gateway.yml, etc.

config-server/Dockerfile

FROM eclipse-temurin:17-jdk
WORKDIR /app
COPY build/libs/config-server.jar /app/config-server.jar
COPY config-repo /opt/config-repo
ENV SPRING_PROFILES_ACTIVE=native
ENV SPRING_CLOUD_CONFIG_SERVER_NATIVE_SEARCH_LOCATIONS=file:/opt/config-repo
ENTRYPOINT ["java","-jar","/app/config-server.jar"]

3.3 Movie / Booking / Gateway / Discovery images

These are standard Spring Boot images — copy the fat jar and any needed static files.

Generic service/Dockerfile

FROM eclipse-temurin:17-jdk
WORKDIR /app
COPY build/libs/service-name.jar /app/service.jar
# copy entrypoints if you want the wait scripts present
COPY entrypoints /opt/entrypoints
ENTRYPOINT ["java","-jar","/app/service.jar"]


Replace service-name.jar accordingly when building.

Important: If you want services to find config-server by env var, you can set default SPRING_CLOUD_CONFIG_URI inside the image by creating application-default.yml or by having the jar’s application.yml include a sensible default. But runtime env vars (passed via -e) are fine.

3.4 MongoDB image (optional: initial data)

Mongo’s official image executes scripts in /docker-entrypoint-initdb.d/ on first run. To include initial data:

mongo/Dockerfile

FROM mongo:6.0
COPY mongo/initdb /docker-entrypoint-initdb.d/


Put *.js scripts or restore.sh that calls mongorestore and include a dump directory if you want to preload data.

4) Build images (PC A or PC B)

You can build with Docker or Podman. Example with docker:

# from repo root
docker build -t ghcr.io/you/keycloak-cinema:latest ./keycloak
docker build -t ghcr.io/you/config-server:latest ./config-server
docker build -t ghcr.io/you/discovery:latest ./discovery
docker build -t ghcr.io/you/gateway:latest ./gateway
docker build -t ghcr.io/you/movie-service:1.0 ./movie-service
docker build -t ghcr.io/you/booking-service:1.0 ./booking-service
docker build -t ghcr.io/you/mongo-init:latest ./mongo  # if you made custom mongo


If using Podman to build:

podman build -t ghcr.io/you/keycloak-cinema:latest ./keycloak
# etc.

5) Transport images to PC B

Two options:

Option A — push to a registry (recommended)

Tag & push to GitHub Container Registry (GHCR) or Docker Hub.

docker login ghcr.io
docker push ghcr.io/you/keycloak-cinema:latest
# repeat for other images


On PC B:

podman login ghcr.io
podman pull ghcr.io/you/keycloak-cinema:latest
# repeat

Option B — export to tar and move (offline)

On PC A:

docker save -o images.tar ghcr.io/you/keycloak-cinema:latest ghcr.io/you/movie-service:1.0 ghcr.io/you/booking-service:1.0 ghcr.io/you/config-server:latest ghcr.io/you/discovery:latest ghcr.io/you/gateway:latest


Transfer images.tar to PC B (scp / usb). On PC B:

podman load -i images.tar

6) Files you still need on PC B (unless you baked them)

secrets/booking_client_secret.txt (unless you baked the secret into Keycloak image and/or booking-service image).

If you didn’t bake Keycloak realm into image: keycloak/realms/cinema-realm.json and keycloak/init/assign-service-account-role.sh.

entrypoints/ scripts (wait scripts) if not baked into images.

If you did bake realm and entrypoint scripts per earlier Dockerfiles, you only need to provide the booking_client_secret (prefer to mount it at runtime) or use Podman secrets.

7) Run containers on PC B with Podman — order and exact commands

Below is the exact order and commands. Replace ghcr.io/you/... with the image names you used, and replace /path/on/pcb/... with your actual local paths.

Create network and volumes:

podman network create cinema-net
podman volume create mongo_data
podman volume create keycloak_data

7.1 Start Mongo

If you used a plain mongo image:

podman run -d --name mongo --network cinema-net \
  -v mongo_data:/data/db \
  -p 27018:27017 \
  docker.io/library/mongo:6.0 \
  --replSet rs0 --bind_ip_all


If you built ghcr.io/you/mongo-init:latest with initial data, use that image instead.

Wait until Mongo answers:

until podman exec mongo mongo --eval "db.adminCommand('ping')" 2>/dev/null | grep -q ok; do sleep 1; done

7.2 Start Keycloak (baked image)

If you baked everything into keycloak-cinema:

podman run -d --name keycloak --network cinema-net -p 8080:8080 \
  -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \
  ghcr.io/you/keycloak-cinema:latest


If you did not bake realm into image and need to mount realm + init:

podman run -d --name keycloak --network cinema-net -p 8080:8080 \
  -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \
  -v /path/on/pcb/keycloak/realms:/opt/keycloak/data/import:Z \
  -v /path/on/pcb/keycloak/init:/opt/keycloak-init:Z \
  quay.io/keycloak/keycloak:latest start-dev --import-realm


If not baked: run the init script one-off after Keycloak is reachable (this assigns MOVIE_CHECK to the booking service account):

podman run --rm --network cinema-net \
  -v /path/on/pcb/keycloak/init:/opt/keycloak-init:Z \
  docker.io/library/alpine:3.18 sh -c "apk add --no-cache curl jq >/dev/null 2>&1 && /opt/keycloak-init/assign-service-account-role.sh"


Wait for Keycloak:

until curl -sSf http://localhost:8080/realms/master/.well-known/openid-configuration >/dev/null 2>&1; do sleep 1; done

7.3 Start Config Server

If the image has embedded config (native profile):

podman run -d --name config-server --network cinema-net -p 8888:8888 \
  -e SPRING_PROFILES_ACTIVE=native \
  ghcr.io/you/config-server:latest


If config server needs to access a remote Git repo, ensure network access and credentials.

Wait:

until curl -sSf http://localhost:8888/actuator/health >/dev/null 2>&1; do sleep 1; done

7.4 Start Discovery (Eureka)
podman run -d --name discovery --network cinema-net -p 8761:8761 \
  ghcr.io/you/discovery:latest


Wait:

until curl -sSf http://localhost:8761/actuator/health >/dev/null 2>&1; do sleep 1; done

7.5 Start Movie service (it depends on config, discovery and mongo)

If you baked the wait entrypoint into the image, run normally. If not, use the mounted entrypoint and run it explicitly:

podman run -d --name movie-service --network cinema-net -p 8100:8080 \
  -e SPRING_CLOUD_CONFIG_URI=http://config-server:8888 \
  -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://discovery:8761/eureka/ \
  -e SPRING_DATA_MONGODB_URI=mongodb://mongo:27017/moviesdb \
  -v /path/on/pcb/entrypoints:/opt/entrypoints:Z \
  ghcr.io/you/movie-service:1.0 \
  /bin/sh -c "/opt/entrypoints/wait-for-mongo-config-eureka.sh && java -jar /app/movie-service.jar"

7.6 Start Booking service (needs Keycloak + secret + mongo + config + discovery)

Place secrets/booking_client_secret.txt on PC B (content must match client secret in Keycloak realm JSON, e.g. booking-secret-please-change), then mount it or use Podman secret.

Option A — mount secret file (simplest)
podman run -d --name booking-service --network cinema-net -p 8200:8080 \
  -e SPRING_CLOUD_CONFIG_URI=http://config-server:8888 \
  -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://discovery:8761/eureka/ \
  -e SPRING_DATA_MONGODB_URI=mongodb://mongo:27017/bookingsdb \
  -e BOOKING_CLIENT_ID=booking-service \
  -e KEYCLOAK_URL=http://keycloak:8080 \
  -e KEYCLOAK_REALM=cinema \
  -v /path/on/pcb/entrypoints:/opt/entrypoints:Z \
  -v /path/on/pcb/secrets/booking_client_secret.txt:/run/secrets/booking_client_secret:ro \
  ghcr.io/you/booking-service:1.0 \
  /bin/sh -c "/opt/entrypoints/wait-for-keycloak-mongo-config-eureka.sh && java -jar /app/booking-service.jar"

Option B — Podman secret + podman play kube (more advanced)

Create secret:

podman secret create booking_client_secret /path/on/pcb/secrets/booking_client_secret.txt


Use with Kubernetes YAML and podman play kube (Podman will map the secret into the pod). If you want me to produce k8s manifests, say so.

7.7 Start Gateway
podman run -d --name gateway --network cinema-net -p 8081:8080 \
  -e SPRING_CLOUD_CONFIG_URI=http://config-server:8888 \
  -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://discovery:8761/eureka/ \
  ghcr.io/you/gateway:latest

8) Verify everything

Keycloak admin console: http://PC_B_IP:8080 (login with admin / admin if you used those env vars). Check realm cinema, roles, clients, users.

Get client credentials token (booking service test):

curl -s -X POST "http://localhost:8080/realms/cinema/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=booking-service" \
  -d "client_secret=$(cat /path/on/pcb/secrets/booking_client_secret.txt)" | jq


If you get access_token JSON, the client secret is correct and KC grants roles. Decode the token (jwt.io or jq + base64) and verify realm_access.roles contains MOVIE_CHECK.

Eureka UI: http://PC_B_IP:8761 — check services movie-service, booking-service, gateway are registered.

Config Server: http://PC_B_IP:8888/movie-service/default to view served config.

Service actuator health endpoints:

http://PC_B_IP:8100/actuator/health

http://PC_B_IP:8200/actuator/health

Tail logs for any failing service:

podman logs -f booking-service
podman logs -f keycloak
podman logs -f movie-service

9) Export/import volumes & DB data (if you need runtime data)

Images do not contain volume contents. To move Mongo data from PC A to PC B, do one of these:

Option 1 — mongodump / mongorestore (recommended)

On PC A:

mongodump --host localhost --port 27017 --out dump/
tar czf mongo_dump.tgz dump/
scp mongo_dump.tgz user@pcb:/tmp/


On PC B:

tar xzf mongo_dump.tgz
# run mongorestore against running mongo on PC B
mongorestore --host localhost --port 27017 dump/

Option 2 — export Docker volume to a tar

On PC A:

docker run --rm -v mongo_data:/data -v "$(pwd)":/backup alpine \
  sh -c "cd /data && tar cvf /backup/mongo_data.tar ."
# copy mongo_data.tar to PC B


On PC B:

podman volume create mongo_data
podman run --rm -v mongo_data:/data -v "$(pwd)":/backup alpine \
  sh -c "cd /data && tar xvf /backup/mongo_data.tar"


Repeat for keycloak_data if you used persistent Keycloak data rather than baked realm.

10) Multi-arch builds (if PC B architecture differs)

If PC B is arm64 and PC A amd64, do either:

Build multi-arch images with docker buildx and push them to registry (recommended), or

Rebuild images on PC B (you can transfer source and build there).

Example multi-arch build (PC A with buildx set up):

docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/you/movie-service:1.0 --push ./movie-service

11) Troubleshooting & common pitfalls

Booking returns 401/403: ensure client id + secret match what Keycloak has. Check the booking_client_secret.txt value and Keycloak client secret.

Services not registering in Eureka: make sure EUREKA_CLIENT_SERVICEURL_DEFAULTZONE is set correctly and discovery is reachable. Check service logs for bootstrap errors.

Config not found: ensure Config Server is up and either points to a reachable Git repo (with configs under application-name/profile.yml) or is running in native profile with embedded config-repo.

Port collisions / rootless Podman networking: rootless Podman sometimes has restrictions on binding low ports. If bind fails, try different ports or run with root privileges.

SELinux: use :Z on -v mounts if SELinux blocks access.

Permission denied when running init scripts: set chmod +x on scripts before building.

12) Full run-with-podman.sh (ready for PC B)

Drop this script on PC B, edit the placeholder paths and image names, make it executable and run. It creates network, volumes, starts containers in order and runs the Keycloak init if using mounts.

#!/bin/sh
set -eu

# EDIT THESE paths & image names for PC B
ENTRYPOINTS_DIR="/path/on/pcb/entrypoints"
SECRETS_DIR="/path/on/pcb/secrets"
KEYCLOAK_REALM_MOUNT="/path/on/pcb/keycloak/realms"
KEYCLOAK_INIT_MOUNT="/path/on/pcb/keycloak/init"

IMAGE_KEYCLOAK="ghcr.io/you/keycloak-cinema:latest"
IMAGE_MONGO="docker.io/library/mongo:6.0"
IMAGE_CONFIG="ghcr.io/you/config-server:latest"
IMAGE_DISCOVERY="ghcr.io/you/discovery:latest"
IMAGE_MOVIE="ghcr.io/you/movie-service:1.0"
IMAGE_BOOKING="ghcr.io/you/booking-service:1.0"
IMAGE_GATEWAY="ghcr.io/you/gateway:latest"

podman network create cinema-net || true
podman volume create mongo_data || true
podman volume create keycloak_data || true

echo "Start mongo..."
podman run -d --name mongo --network cinema-net -v mongo_data:/data/db -p 27018:27017 ${IMAGE_MONGO} --replSet rs0 --bind_ip_all
until podman exec mongo mongo --eval "db.adminCommand('ping')" 2>/dev/null | grep -q ok; do sleep 2; done

echo "Start keycloak..."
# If realm baked into image:
podman run -d --name keycloak --network cinema-net -p 8080:8080 -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin ${IMAGE_KEYCLOAK}
# If not baked, use the upstream image with mounts:
# podman run -d --name keycloak --network cinema-net -p 8080:8080 -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \
#   -v ${KEYCLOAK_REALM_MOUNT}:/opt/keycloak/data/import:Z -v ${KEYCLOAK_INIT_MOUNT}:/opt/keycloak-init:Z \
#   quay.io/keycloak/keycloak:latest start-dev --import-realm

until curl -sSf http://localhost:8080/realms/master/.well-known/openid-configuration >/dev/null 2>&1; do sleep 2; done

# If using mounts and need to run init:
if [ -d "${KEYCLOAK_INIT_MOUNT}" ]; then
  podman run --rm --network cinema-net -v ${KEYCLOAK_INIT_MOUNT}:/opt/keycloak-init:Z docker.io/library/alpine:3.18 sh -c "apk add --no-cache curl jq >/dev/null 2>&1 && /opt/keycloak-init/assign-service-account-role.sh"
fi

echo "Start config-server..."
podman run -d --name config-server --network cinema-net -p 8888:8888 -e SPRING_PROFILES_ACTIVE=native ${IMAGE_CONFIG}
until curl -sSf http://localhost:8888/actuator/health >/dev/null 2>&1; do sleep 2; done

echo "Start discovery..."
podman run -d --name discovery --network cinema-net -p 8761:8761 ${IMAGE_DISCOVERY}
until curl -sSf http://localhost:8761/actuator/health >/dev/null 2>&1; do sleep 2; done

echo "Start movie-service..."
podman run -d --name movie-service --network cinema-net -p 8100:8080 \
  -e SPRING_CLOUD_CONFIG_URI=http://config-server:8888 \
  -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://discovery:8761/eureka/ \
  -e SPRING_DATA_MONGODB_URI=mongodb://mongo:27017/moviesdb \
  -v ${ENTRYPOINTS_DIR}:/opt/entrypoints:Z \
  ${IMAGE_MOVIE} /bin/sh -c "/opt/entrypoints/wait-for-mongo-config-eureka.sh && java -jar /app/movie-service.jar"

echo "Start booking-service..."
podman run -d --name booking-service --network cinema-net -p 8200:8080 \
  -e SPRING_CLOUD_CONFIG_URI=http://config-server:8888 \
  -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://discovery:8761/eureka/ \
  -e SPRING_DATA_MONGODB_URI=mongodb://mongo:27017/bookingsdb \
  -e BOOKING_CLIENT_ID=booking-service \
  -e KEYCLOAK_URL=http://keycloak:8080 \
  -e KEYCLOAK_REALM=cinema \
  -v ${ENTRYPOINTS_DIR}:/opt/entrypoints:Z \
  -v ${SECRETS_DIR}/booking_client_secret.txt:/run/secrets/booking_client_secret:ro \
  ${IMAGE_BOOKING} /bin/sh -c "/opt/entrypoints/wait-for-keycloak-mongo-config-eureka.sh && java -jar /app/booking-service.jar"

echo "Start gateway..."
podman run -d --name gateway --network cinema-net -p 8081:8080 \
  -e SPRING_CLOUD_CONFIG_URI=http://config-server:8888 \
  -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://discovery:8761/eureka/ \
  ${IMAGE_GATEWAY}

echo "All started. Use 'podman ps' and 'podman logs -f <name>' to inspect."

13) Final checklist before you press enter

 Decide whether you bake realm & configs into images (makes PC B simpler) or mount them at runtime (more secure/clean).

 If not baking secrets, copy secrets/booking_client_secret.txt to PC B before running.

 Ensure image CPU architecture matches PC B or build multi-arch images.

 If you need DB data moved, use mongodump / mongorestore.

 Use the run-with-podman.sh script (edit placeholders) to start everything automatically.
