#!/usr/bin/env bash

set -e

PODNAME="insights"
WORKDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
WAIT_FOR_CMD="${WORKDIR}/check-response-code.sh"

#MINIO_DATA_DIR="${WORKDIR}/../data"
#MINIO_CONFIG_DIR="${WORKDIR}/../config"
MINIO_ACCESS_KEY=BQA2GEXO711FVBVXDWKM
MINIO_SECRET_KEY=uvgz3LCwWM3e400cDkQIH/y1Y4xgU4iV91CwFSPC
INGRESS_VALID_TOPICS=testareno,advisor

#PODMAN_NETWORK="cni-podman1"
#PODMAN_GATEWAY=$(podman network inspect $PODMAN_NETWORK | jq -r '..| .gateway? // empty')

# Variables

POSTGRES_PASSWORD=insights
POSTGRES_USER=insights
POSTGRES_DB=insights

if ! podman pod exists $PODNAME; then
	echo "pod $PODNAME does not exist!"
	exit 1
#	podman pod create --name "$PODNAME"
#	podman pod create --name "$PODNAME" --network "$PODMAN_NETWORK" -p "$MINIO_PORT" \
#		--add-host "ci.foo.redhat.com:$PODMAN_GATEWAY" \
#		--add-host "qa.foo.redhat.com:$PODMAN_GATEWAY" \
#		--add-host "stage.foo.redhat.com:$PODMAN_GATEWAY" \
#		--add-host "prod.foo.redhat.com:$PODMAN_GATEWAY"
fi

#podman build . -t "ingress"

# inventory-db

podman run --pod "$PODNAME" -d --name "inventory-db" \
	-e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
	-e POSTGRES_USER="$POSTGRES_USER" \
	-e POSTGRES_DB="$POSTGRES_DB" \
	-p 15432:5432 \
	postgres

# inventory

podman run --pod "$PODNAME" -d --name "inventory" \
	-e INVENTORY_DB_HOST=localhost \
	-e INVENTORY_DB_USER="$POSTGRES_USER" \
	-e INVENTORY_DB_PASS="$POSTGRES_PASSWORD" \
	-e  APP_NAME=${APP_NAME} \
	-e  PATH_PREFIX=${PATH_PREFIX} \
	-e  INVENTORY_LEGACY_API_URL="/r/insights/platform/inventory/v1/" \
	-e  prometheus_multiproc_dir="/tmp/inventory/prometheus" \
    -e  INVENTORY_LOG_LEVEL="${LOG_LEVEL}" \
	-e  INVENTORY_DB_SSL_MODE="${INVENTORY_DB_SSL_MODE}" \
	-e  INVENTORY_DB_SSL_CERT="${INVENTORY_DB_SSL_CERT}" \
	-e  AWS_ACCESS_KEY_ID="" \
	-e  AWS_SECRET_ACCESS_KEY="" \
	-e  AWS_REGION_NAME="" \
	-e  AWS_LOG_GROUP="" \
	-e  KAFKA_TOPIC="platform.system-profile" \
	-e  KAFKA_GROUP="inventory" \
	-e  KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_HOST}:${KAFKA_BOOTSTRAP_PORT}" \
	-e  PAYLOAD_TRACKER_KAFKA_TOPIC="platform.payload-status" \
	-e  PAYLOAD_TRACKER_SERVICE_NAME="inventory" \
	-e  PAYLOAD_TRACKER_ENABLED="false" \
	-e  XJOIN_GRAPHQL_URL="${XJOIN_SEARCH_URL}" \
	-e  BULK_QUERY_SOURCE="${BULK_QUERY_SOURCE}" \
	-e  BULK_QUERY_SOURCE_BETA="${BULK_QUERY_SOURCE_BETA}" \
	inventory:dev \
    gunicorn --workers=4 \
    --threads=8 --worker-tmp-dir=/gunicorn \
	-c gunicorn.conf.py \
    -b 0.0.0.0:8080 \
    -t "60" run

#
## zookeeper
#podman run --pod "$PODNAME" -d --name "zookeeper" \
#	-e ZOOKEEPER_CLIENT_PORT=32181 \
#	-e ZOOKEEPER_SERVER_ID=1 \
#	confluentinc/cp-zookeeper
#
## kafka
#podman run --pod "$PODNAME" -d --name "kafka" \
#	-e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:29092 \
#	-e KAFKA_BROKER_ID=1 \
#	-e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
#	-e KAFKA_ZOOKEEPER_CONNECT=localhost:32181 \
#	confluentinc/cp-kafka
#
## minio
#podman run --pod "$PODNAME" -d --name "minio" \
#	-e MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY" \
#	-e MINIO_SECRET_KEY="$MINIO_SECRET_KEY" \
#	-v "$MINIO_DATA_DIR:/data:Z" \
#	-v "$MINIO_CONFIG_DIR:/root/.minio:Z" \
#	minio/minio \
#	server /data
#
#until $WAIT_FOR_CMD "http://localhost:${MINIO_PORT}/minio/health/ready" 200 ; do
#	>&2 echo "Minio is not yet ready..."
#	sleep 1
#done
#
## createbuckets
#podman run --pod "$PODNAME" -d --name "createbuckets" \
#	-v "$MINIO_DATA_DIR:/data:Z" \
#	-v "$MINIO_CONFIG_DIR:/root/.minio:Z" \
#	-e MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY" \
#	-e MINIO_SECRET_KEY="$MINIO_SECRET_KEY" \
#    --entrypoint "/bin/sh" \
#	  minio/mc \
#      -c \
#	  "/usr/bin/mc config host add myminio http://localhost:${MINIO_PORT} $MINIO_ACCESS_KEY $MINIO_SECRET_KEY ;\
#	  /usr/bin/mc mb myminio/insights-upload-perma;\
#      /usr/bin/mc mb myminio/insights-upload-rejected;\
#      /usr/bin/mc policy set download myminio/insights-upload-perma;\
#      /usr/bin/mc policy set download myminio/insights-upload-rejected;\
#      exit 0;"
#
#
## ingress
#podman run --pod "$PODNAME" -d --name "ingress" \
#	-v "$MINIO_DATA_DIR:/data:Z" \
#    -e AWS_ACCESS_KEY_ID=$MINIO_ACCESS_KEY \
#	-e AWS_SECRET_ACCESS_KEY=$MINIO_SECRET_KEY \
#    -e AWS_REGION=us-east-1 \
#    -e INGRESS_STAGEBUCKET=insights-upload-perma \
#    -e INGRESS_REJECTBUCKET=insights-upload-rejected \
#    -e INGRESS_INVENTORYURL=https://ci.foo.redhat.com:1337/api/inventory/v1/hosts \
#    -e INGRESS_VALIDTOPICS=$INGRESS_VALID_TOPICS \
#    -e OPENSHIFT_BUILD_COMMIT=woopwoop \
#    -e INGRESS_MINIODEV=true \
#    -e INGRESS_MINIOACCESSKEY=$MINIO_ACCESS_KEY \
#    -e INGRESS_MINIOSECRETKEY=$MINIO_SECRET_KEY \
#    -e INGRESS_MINIOENDPOINT=localhost:${MINIO_PORT}\
#	ingress:latest
#
