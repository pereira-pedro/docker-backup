#!/bin/bash

LOG_DB=false
LOG_VERBOSE=true

BACKUP_DATA=$(pwd)
ROOT_DIR=${BACKUP_DATA}/$(date '+%Y%m%d%H%M%S')
if result=$(mkdir -p ${ROOT_DIR}) 2>&1; then
    logger -p local0.info -t "Docker Backup" "Starting backup on ${ROOT_DIR}"
else
    logger -p local0.error -t "Docker Backup" "$result"
    exit 1
fi

LOG_FILE=${ROOT_DIR}/docker-backup.log

log() {
    message="[$(date '+%F %T')] [$3] [$2:$1] [$4]"
    if [[ "$LOG_VERBOSE" == true ]]; then
        echo "$message"
    fi

    # if [[ "$LOG_DB" == true ]]; then

    # fi

    echo "$message" >>${LOG_FILE}
}

log_info() {
    log "$1" "$2" "INFO" "$3"
}

log_warning() {
    log "$1" "$2" "WARNING" "$3"
}

log_error() {
    log "$1" "$2" "ERROR" "$3"
}

for container in $(docker container ls -a --no-trunc --quiet --format "{{.ID}},{{.Names}},{{.Mounts}}"); do
    id=$(echo $container | awk -F "," '{print $1}')
    name=$(echo $container | awk -F "," '{print $2}')
    mounts=$(echo $container | awk -F "," '{print $3}')
    if [[ -z "$mounts" ]]; then
        continue
    fi

    is_running=$(docker container inspect -f '{{.State.Running}}' $name)

    if [[ "$is_running" == "true" ]]; then
        log_info "$id" "$name" "Stopping '$name'..."
        docker stop $name >/dev/null

        if [ "$(docker container inspect -f '{{.State.Running}}' $name)" == "true" ]; then
            log_warning "$id" "$name" "Unable to backup '$name'. The container is not stopped."
            continue
        fi

        log_info "$id" "$name" "'$name' stopped successfully."
    else
        log_info "$id" "$name" "'$name' is already stopped."
    fi

    log_info "$id" "$name" "Found the following mounts: $mounts"
    for volume in ${mounts//,/ }; do
        log_info "$id" "$name" "Will start backup for mount '$volume'"
        backup_file_name=${volume//[^[:alnum:]-]/_}-$(date '+%Y%m%d%H%M%S').tar.gz
        log_info "$id" "$name" "Backup to '${backup_file_name}' started."
        #docker run --rm -v "$volume":/backup-volume -v "${BACKUP_DATA}":/backup busybox tar -zcf /backup/$backup_file_name /backup-volume
        if result=$(docker run --rm -v "$volume":/to-backup -v "${ROOT_DIR}/data":/backup busybox tar -zcf /backup/$backup_file_name /to-backup 2>&1); then
            log_info "$id" "$name" "Backup for '${backup_file_name}' completed successfully."
        else
            log_error "$id" "$name" "Backup failed with error: $result ($?)"
        fi
    done

    if [ "$is_running" == "true" ]; then
        log_info "$id" "$name" "Starting '$name'..."
        docker start $name >/dev/null

        if [ "$(docker container inspect -f '{{.State.Running}}' $name)" == "false" ]; then
            log_error "$id" "$name" "'$name' not started."
        else
            log_info "$id" "$name" "'$name' started successfully."
        fi
    else
        log_info "$id" "$name" "No need to start '$name', it was previously stopped."
    fi
done
