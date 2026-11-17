#!/usr/bin/env bash
# Helpers for the ARM64 Docker-CPI director from aws-samples/sample-cloud-foundry-graviton.
# Source this file. Its API listens on 127.0.0.1 inside the director container
# (plain HTTP, generated basic-auth credentials), so every call goes through
# `docker exec`, the same way the sample's scripts/deploy-sample.sh does it.

DIRECTOR_CONTAINER="${DIRECTOR_CONTAINER:-bosh-director}"
DIRECTOR_URL="http://127.0.0.1:25555"
DIRECTOR_CREDS=/var/vcap/bosh/etc/director-creds.env

# director_curl <curl args...>: curl against the director API with its credentials.
director_curl() {
  docker exec -i "$DIRECTOR_CONTAINER" sh -c '. '"$DIRECTOR_CREDS"' && exec curl -sS -u "$BOSH_ADMIN_USER:$BOSH_ADMIN_PASSWORD" "$@"' curl "$@"
}

# director_wait_api <seconds>: waits until GET /info answers.
director_wait_api() {
  local deadline=$((SECONDS + $1))
  until director_curl -f "${DIRECTOR_URL}/info" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "director API not ready after $1s" >&2
      docker logs --tail 50 "$DIRECTOR_CONTAINER" >&2 || true
      return 1
    fi
    sleep 5
  done
  director_curl "${DIRECTOR_URL}/info"
  echo
}

# director_task <curl args...>: starts a task (the API redirects to /tasks/<id>) and prints its id.
director_task() {
  local location id
  location=$(director_curl -o /dev/null -w '%{redirect_url}' "$@")
  id="${location##*/}"
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "no task started (redirect: '${location}')" >&2
    return 1
  fi
  echo "$id"
}

# director_wait_task <id> <seconds>: waits for a task; prints its output and fails unless it is done.
director_wait_task() {
  local id="$1" deadline=$((SECONDS + $2)) state=""
  echo "task ${id}: waiting (up to $2s)"
  while [ "$SECONDS" -lt "$deadline" ]; do
    state=$(director_curl "${DIRECTOR_URL}/tasks/${id}" | jq -r .state)
    case "$state" in
      done|error|cancelled|timeout) break ;;
    esac
    sleep 10
  done
  director_curl "${DIRECTOR_URL}/tasks/${id}/output?type=event" \
    | jq -r 'select(.stage != null) | "\(.time | todate) | \(.stage): \(.task) \(.state)\(if .data.error then " - " + .data.error else "" end)"' || true
  director_curl "${DIRECTOR_URL}/tasks/${id}" | jq -r '"task \(.id): \(.state) - \(.result)"'
  [ "$state" = "done" ]
}

# director_upload <stemcells|releases> <local file> <seconds>: uploads a tarball and waits for the task.
director_upload() {
  local kind="$1" file="$2" id
  docker cp "$file" "${DIRECTOR_CONTAINER}:/tmp/upload-${kind}.tgz"
  id=$(director_task -X POST -H "Content-Type: multipart/form-data" \
    -F "nginx_upload_path=/tmp/upload-${kind}.tgz" "${DIRECTOR_URL}/${kind}")
  director_wait_task "$id" "$3"
}
