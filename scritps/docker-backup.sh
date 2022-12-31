#!/bin/bash

LOG_DB=false
LOG_VERBOSE=true
BACKUP_DIR=/var/spool/docker-backup
BACKUP_NAME=$(date '+%Y%m%d%H%M%S')
ROOT_DIR=${BACKUP_DIR}/${BACKUP_NAME}

STORAGE_S3_CONFIG=/usr/share/pontonet/rclone.conf
STORAGE_S3_NAME=eu2
STORAGE_S3_BUCKET=docker-backup
STORAGE_S3_PATH=${STORAGE_S3_NAME}:${STORAGE_S3_BUCKET}/bck-${BACKUP_NAME}

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

already_backuped() {
    local backuped="false"
    for element in "${volumes_backuped}"; do
        if [[ "$element" == "$1" ]]; then
            backuped="true"
            break
        fi
    done

    echo $backuped
}

store_s3() {
    log info $1 $2 "Starting saving '$3' on S3 storage service."
    rclone sync $3 ${STORAGE_S3_PATH} --config ${STORAGE_S3_CONFIG}

    if [[ $? -eq 1 ]]; then
        log info $1 $2 "Starting saving '$3' on S3 storage service."
    else
        log error $1 $2 "Error saving '$3' to S3 storage service."
    fi
}

save_on_cloud() {
    log info $1 $2 "Starting saving '$3' on cloud."
    local saved=0
    [ -z "$STORAGE_S3_PATH" ] && store_s3 $1 $2 $3 || saved=1

    if [[ $saved -eq 1 ]]; then
        log info $1 $2 "No cloud service set for '$3'."
    else
        log info $1 $2 "'$3' saved on cloud."
    fi
}

volumes_backuped=()
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
        if [ "$(already_backuped $volume)" == "true" ]; then
            log_info "$id" "$name" "No need to backup '${volume}'. Already backuped"
            continue
        fi
        log_info "$id" "$name" "Will start backup for mount '$volume'"
        backup_file_name=${volume//[^[:alnum:]-]/_}-$(date '+%Y%m%d%H%M%S').tar.gz

        log_info "$id" "$name" "Backup to '${backup_file_name}' started."
        if result=$(docker run --rm -v "$volume":/bck -v "${ROOT_DIR}/data":/backup busybox tar -zcf /backup/$backup_file_name /bck 2>&1); then
            log_info "$id" "$name" "Backup for '${backup_file_name}' completed successfully."
            volumes_backuped+=($volume)
        else
            log_error "$id" "$name" "Backup failed with error: $result ($?)"
        fi

        save_on_cloud "$id" "$name" "${ROOT_DIR}/data/$backup_file_name" &
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
