#!/bin/bash

set -e
set -o pipefail

NODES=${NODES?:'[error] Must provide number of NODES for cluster configuration'}
ELASTICSEARCH_HOME="/usr/share/elasticsearch"
BIN_DIR="${ELASTICSEARCH_HOME}/bin"
CONFIG_DIR="${ELASTICSEARCH_HOME}/config"
ELASTICSEARCH_YML="${CONFIG_DIR}/elasticsearch.yml"
KEYSTORE_SECRETS_DIR="/secrets/keystore"
KEYSTORE_PASSWORD_FILE="keystore.password"

add_to_keystore() {
  key="${1}"
  val="${2}"
  keystore_password="${3}"

  if [ -z "${key}" ] || [ -z "${val}" ]; then
    echo "Empty values sent to add_to_keystore [key=${key}, val=REDACTED]"
    return
  else
    # add secure property to keystore (with optional password)
    if [ -n "${keystore_password}" ]; then
      ${BIN_DIR}/elasticsearch-keystore add "${key}" <<EOF
${keystore_password}
${val}
EOF
      ${BIN_DIR}/elasticsearch-keystore list "${key}" >/dev/null 2>&1 <<EOF
${keystore_password}
EOF
      rc=$?
    else
      echo "${val}" | ${BIN_DIR}/elasticsearch-keystore add --stdin "${key}"
      ${BIN_DIR}/elasticsearch-keystore list "${key}" >/dev/null 2>&1
      rc=$?
    fi

    # check key was found in keystore after the operation
    if [ $rc -ne 0 ]; then
      echo "There was an error adding ${key} to keystore"
      exit 1
    fi
  fi
}

# copy any injected config files to correct directory
if [ -d "${CONFIG_DIR}/injected" ]; then
  cp -vb ${CONFIG_DIR}/injected/* ${CONFIG_DIR}
fi

# update elasticsearch.yml with expected node details
if [ -n "${NODES}" ] && [ "${NODES}" -gt "0" ]; then
  if [ "${NODES}" -eq "1" ] && [ "true" != "${DISABLE_SINGLE_NODE}" ]; then
    # enable single-node discovery if only a single instance configured and mode not disabled
    echo "Enabling single-node discovery mode (cluster cannot be scaled)"
    sed -i -e "s/#discovery.type: single-node/discovery.type: single-node/" ${ELASTICSEARCH_YML}
  else
    # build list of hosts for discovery and master election
    HOST=$(hostname -s)

    if [[ ${HOST} =~ (.*)-([0-9]+)$ ]]; then
      NAME=${BASH_REMATCH[1]}
      ORD=${BASH_REMATCH[2]}
    else
      echo "Failed to parse name and ordinal of Pod (Host: ${HOST})"
      exit 1
    fi

    echo "Configuring Cluster for [${NODES}] nodes on server [${ORD}] with name prefix [${NAME}]"
    NODE_LIST=""
    for ((i = 1; i <= NODES; i++)); do
      NODE="${NAME}-$((i - 1)).$(dnsdomainname)"

      echo "Adding entry '${NODE}' to cluster lists"

      if [ "${NODE_LIST}" != "" ]; then
        NODE_LIST="${NODE_LIST}, "
      fi
      NODE_LIST="${NODE_LIST}\"${NODE}\""
    done
    NODE_LIST="[ ${NODE_LIST} ]"

    echo "Generated (initial) cluster node list: ${NODE_LIST}"
    sed -ie "s/#discovery.seed_hosts:/discovery.seed_hosts: ${NODE_LIST}/" ${ELASTICSEARCH_YML}
    sed -ie "s/#cluster.initial_master_nodes:/cluster.initial_master_nodes: ${NODE_LIST}/" ${ELASTICSEARCH_YML}
  fi
fi

# use full hostname for network connectivity (node.name and network.publish_host)
NODE_NAME=$(hostname -f)
export NODE_NAME
sed -ie "s/node.name:.*/node.name: ${NODE_NAME}/" ${ELASTICSEARCH_YML}
sed -ie "s/network.publish_host:.*/network.publish_host: ${NODE_NAME}/" ${ELASTICSEARCH_YML}

# Create keystore (with optional password)
keystore_password=
if [ -f "${KEYSTORE_SECRETS_DIR}/${KEYSTORE_PASSWORD_FILE}" ]; then
  keystore_password=$(head -1 "${KEYSTORE_SECRETS_DIR}/${KEYSTORE_PASSWORD_FILE}")
  ${BIN_DIR}/elasticsearch-keystore create -p <<EOF
${keystore_password}
${keystore_password}
EOF
else
  ${BIN_DIR}/elasticsearch-keystore create
fi


if [ -d "${KEYSTORE_SECRETS_DIR}" ]; then
  while IFS= read -r -d '' secret; do
    key=$(basename "${secret}")
    if [ "${key}" != "${KEYSTORE_PASSWORD_FILE}" ]; then
      val=$(head -1 "${secret}")

      echo "Add keystore entry for ${key}"
      add_to_keystore "${key}" "${val}" "${keystore_password}"
    fi
  done < <(find "${KEYSTORE_SECRETS_DIR}" -type f -print0)
fi

# run standard Elasticsearch entrypoint script, passing any args submitted to this script along with maintaining the environment variables
/usr/local/bin/docker-entrypoint.sh "$@" &
elasticsearch_pid="$!"

trap "echo Received trapped signal, beginning shutdown...;" TERM HUP INT EXIT

echo "Elasticsearch running with PID ${elasticsearch_pid}."
wait ${elasticsearch_pid}
