#!/system/bin/sh

# Droidspaces Boot Supervisor
# Starts run_at_boot containers and keeps supervised homelab nodes healthy.

MODDIR=${MODDIR:-${0%/*}}
DROIDSPACE_DIR=${DROIDSPACE_DIR:-/data/local/Droidspaces}
LOGS_DIR=${LOGS_DIR:-${DROIDSPACE_DIR}/Logs}
LOGS_FILE=${LOGS_FILE:-${LOGS_DIR}/boot-module.log}
CONTAINERS_DIR=${CONTAINERS_DIR:-${DROIDSPACE_DIR}/Containers}
STATE_DIR=${STATE_DIR:-${DROIDSPACE_DIR}/State/boot-supervisor}
DROIDSPACE_BINARY=${DROIDSPACE_BINARY:-${DROIDSPACE_DIR}/bin/droidspaces}
BUSYBOX_BINARY=${BUSYBOX_BINARY:-${DROIDSPACE_DIR}/bin/busybox}

BOOT_WAIT_SECONDS=${BOOT_WAIT_SECONDS:-25}
SUPERVISOR_SCAN_INTERVAL_SEC=${SUPERVISOR_SCAN_INTERVAL_SEC:-30}
DEFAULT_HEALTH_INTERVAL_SEC=${DEFAULT_HEALTH_INTERVAL_SEC:-30}
DEFAULT_FAILURE_THRESHOLD=${DEFAULT_FAILURE_THRESHOLD:-3}
DEFAULT_INITIAL_BACKOFF_SEC=${DEFAULT_INITIAL_BACKOFF_SEC:-5}
DEFAULT_MAX_BACKOFF_SEC=${DEFAULT_MAX_BACKOFF_SEC:-300}
DEFAULT_DISK_PRESSURE_THRESHOLD_PERCENT=${DEFAULT_DISK_PRESSURE_THRESHOLD_PERCENT:-90}

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$(date +%s)")
    echo "[${timestamp}] $*"
}

bb() {
    if [ -x "${BUSYBOX_BINARY}" ]; then
        "${BUSYBOX_BINARY}" "$@"
    else
        "$@"
    fi
}

ensure_parent_dir() {
    local path="$1"
    mkdir -p "$(dirname "${path}")" 2>/dev/null
}

numeric_or_default() {
    local value="$1"
    local fallback="$2"
    case "${value}" in
        ''|*[!0-9]*)
            echo "${fallback}"
            ;;
        *)
            echo "${value}"
            ;;
    esac
}

normalize_profile() {
    case "$1" in
        k3s|k3s-node|k3s_node)
            echo "k3s_node"
            ;;
        *)
            echo "standard"
            ;;
    esac
}

get_config_value() {
    local config_file="$1"
    local key="$2"
    bb grep "^${key}=" "${config_file}" 2>/dev/null | bb head -1 | bb sed 's/^[^=]*=//' | bb tr -d '\r\n'
}

get_container_dir_id() {
    basename "$(dirname "$1")"
}

get_container_name() {
    local cfg="$1"
    local name
    name=$(get_config_value "${cfg}" "name")
    if [ -n "${name}" ]; then
        echo "${name}"
    else
        get_container_dir_id "${cfg}"
    fi
}

get_display_name() {
    get_container_name "$1"
}

get_state_file() {
    local cfg="$1"
    echo "${STATE_DIR}/$(get_container_dir_id "${cfg}").state"
}

get_state_value() {
    local cfg="$1"
    local key="$2"
    local state_file
    state_file=$(get_state_file "${cfg}")
    if [ ! -f "${state_file}" ]; then
        return 0
    fi
    bb grep "^${key}=" "${state_file}" 2>/dev/null | bb head -1 | bb sed 's/^[^=]*=//' | bb tr -d '\r\n'
}

set_state_value() {
    local cfg="$1"
    local key="$2"
    local value="$3"
    local state_file tmp_file
    state_file=$(get_state_file "${cfg}")
    tmp_file="${state_file}.tmp"

    ensure_parent_dir "${state_file}"
    {
        if [ -f "${state_file}" ]; then
            bb grep -v "^${key}=" "${state_file}" 2>/dev/null
        fi
        echo "${key}=${value}"
    } > "${tmp_file}"
    mv "${tmp_file}" "${state_file}"
}

reset_health_state() {
    local cfg="$1"
    local now initial_backoff
    now=$(date +%s 2>/dev/null || echo 0)
    initial_backoff=$(effective_initial_backoff "${cfg}")
    set_state_value "${cfg}" "failure_count" "0"
    set_state_value "${cfg}" "next_restart_epoch" "0"
    set_state_value "${cfg}" "restart_backoff_sec" "${initial_backoff}"
    set_state_value "${cfg}" "last_health_epoch" "${now}"
}

increment_state_value() {
    local cfg="$1"
    local key="$2"
    local current
    current=$(numeric_or_default "$(get_state_value "${cfg}" "${key}")" "0")
    current=$((current + 1))
    set_state_value "${cfg}" "${key}" "${current}"
    echo "${current}"
}

should_run_at_boot() {
    [ "$(get_config_value "$1" "run_at_boot")" = "1" ]
}

is_supervision_enabled() {
    local cfg="$1"
    local explicit profile
    explicit=$(get_config_value "${cfg}" "supervision_enabled")
    if [ -n "${explicit}" ]; then
        [ "${explicit}" = "1" ]
        return $?
    fi

    profile=$(normalize_profile "$(get_config_value "${cfg}" "workload_profile")")
    [ "${profile}" = "k3s_node" ]
}

effective_health_type() {
    local cfg="$1"
    local explicit profile
    explicit=$(get_config_value "${cfg}" "healthcheck_type")
    if [ -n "${explicit}" ]; then
        echo "${explicit}"
        return 0
    fi

    profile=$(normalize_profile "$(get_config_value "${cfg}" "workload_profile")")
    if [ "${profile}" = "k3s_node" ]; then
        echo "k3s"
    else
        echo "none"
    fi
}

effective_health_interval() {
    numeric_or_default \
        "$(get_config_value "$1" "healthcheck_interval_sec")" \
        "${DEFAULT_HEALTH_INTERVAL_SEC}"
}

effective_failure_threshold() {
    numeric_or_default \
        "$(get_config_value "$1" "healthcheck_failures_before_restart")" \
        "${DEFAULT_FAILURE_THRESHOLD}"
}

effective_initial_backoff() {
    numeric_or_default \
        "$(get_config_value "$1" "restart_initial_backoff_sec")" \
        "${DEFAULT_INITIAL_BACKOFF_SEC}"
}

effective_max_backoff() {
    numeric_or_default \
        "$(get_config_value "$1" "restart_max_backoff_sec")" \
        "${DEFAULT_MAX_BACKOFF_SEC}"
}

effective_k3s_service() {
    local value
    value=$(get_config_value "$1" "healthcheck_service")
    case "${value}" in
        ''|*[!A-Za-z0-9_.@-]*)
            echo "k3s"
            ;;
        *)
            echo "${value}"
            ;;
    esac
}

effective_k3s_url() {
    local value
    value=$(get_config_value "$1" "healthcheck_url")
    case "${value}" in
        ''|*[!A-Za-z0-9:/._?=%+-]*)
            echo "https://127.0.0.1:6443/readyz"
            ;;
        *)
            echo "${value}"
            ;;
    esac
}

effective_disk_pressure_threshold() {
    numeric_or_default \
        "$(get_config_value "$1" "disk_pressure_threshold_percent")" \
        "${DEFAULT_DISK_PRESSURE_THRESHOLD_PERCENT}"
}

container_pid() {
    local name output
    name=$(get_container_name "$1")
    output=$("${DROIDSPACE_BINARY}" --name "${name}" pid 2>/dev/null | bb head -1 | bb tr -d '\r\n')
    case "${output}" in
        ''|NONE|*[!0-9]*)
            return 1
            ;;
        *)
            echo "${output}"
            return 0
            ;;
    esac
}

is_container_running() {
    container_pid "$1" >/dev/null 2>&1
}

run_in_container() {
    local cfg="$1"
    local name="$2"
    local command="$3"
    "${DROIDSPACE_BINARY}" --name "${name}" run "${command}" >/dev/null 2>&1
}

check_k3s_health() {
    local cfg="$1"
    local name service url disk_threshold command
    name=$(get_container_name "${cfg}")
    service=$(effective_k3s_service "${cfg}")
    url=$(effective_k3s_url "${cfg}")
    disk_threshold=$(effective_disk_pressure_threshold "${cfg}")

    command="svc='${service}'; url='${url}'; threshold='${disk_threshold}'; \
systemctl is-active --quiet \"\$svc\" || exit 1; \
if [ -d /var/lib/rancher/k3s ] && [ \"\$threshold\" -gt 0 ] 2>/dev/null; then \
  set -- \$(df -P /var/lib/rancher/k3s 2>/dev/null | tail -1); \
  use=\${5%%%}; \
  if [ -n \"\$use\" ] && [ \"\$use\" -ge \"\$threshold\" ] 2>/dev/null; then \
    exit 1; \
  fi; \
fi; \
if command -v curl >/dev/null 2>&1; then \
  curl -kfsS \"\$url\" >/dev/null 2>&1 || exit 1; \
elif command -v wget >/dev/null 2>&1; then \
  wget -qO- --no-check-certificate \"\$url\" >/dev/null 2>&1 || exit 1; \
fi"
    run_in_container "${cfg}" "${name}" "${command}"
}

run_healthcheck() {
    local cfg="$1"
    case "$(effective_health_type "${cfg}")" in
        none|'')
            return 0
            ;;
        k3s)
            check_k3s_health "${cfg}"
            return $?
            ;;
        systemd)
            local name service command
            name=$(get_container_name "${cfg}")
            service=$(effective_k3s_service "${cfg}")
            command="systemctl is-active --quiet '${service}'"
            run_in_container "${cfg}" "${name}" "${command}"
            return $?
            ;;
        *)
            return 0
            ;;
    esac
}

schedule_restart() {
    local cfg="$1"
    local display_name="$2"
    local current_backoff scheduled_backoff max_backoff next_epoch restart_count
    local now
    now=$(date +%s 2>/dev/null || echo 0)
    current_backoff=$(numeric_or_default "$(get_state_value "${cfg}" "restart_backoff_sec")" "$(effective_initial_backoff "${cfg}")")
    max_backoff=$(effective_max_backoff "${cfg}")
    scheduled_backoff="${current_backoff}"
    next_epoch=$((now + scheduled_backoff))

    set_state_value "${cfg}" "next_restart_epoch" "${next_epoch}"
    restart_count=$(increment_state_value "${cfg}" "restart_count")

    current_backoff=$((current_backoff * 2))
    if [ "${current_backoff}" -gt "${max_backoff}" ]; then
        current_backoff="${max_backoff}"
    fi
    set_state_value "${cfg}" "restart_backoff_sec" "${current_backoff}"

    log "Supervisor scheduled restart for '${display_name}' in ${scheduled_backoff} seconds (restart #${restart_count})"
}

start_container() {
    local cfg="$1"
    local display_name="$2"
    local reason="$3"

    log "Starting container '${display_name}' (${reason})"
    "${DROIDSPACE_BINARY}" --config "${cfg}" start 2>&1
    local exit_code=$?

    if [ ${exit_code} -eq 0 ]; then
        set_state_value "${cfg}" "started_once" "1"
        reset_health_state "${cfg}"
        log "SUCCESS: Container '${display_name}' started successfully"
        return 0
    fi

    log "FAILED: Container '${display_name}' failed to start (exit code: ${exit_code})"
    return "${exit_code}"
}

stop_container() {
    local cfg="$1"
    local display_name="$2"
    local name
    name=$(get_container_name "${cfg}")
    log "Stopping container '${display_name}' for supervised recovery"
    "${DROIDSPACE_BINARY}" --name "${name}" stop >/dev/null 2>&1
}

handle_running_container() {
    local cfg="$1"
    local display_name="$2"
    local now last_health interval failures threshold
    now=$(date +%s 2>/dev/null || echo 0)
    interval=$(effective_health_interval "${cfg}")
    last_health=$(numeric_or_default "$(get_state_value "${cfg}" "last_health_epoch")" "0")

    if [ $((now - last_health)) -lt "${interval}" ]; then
        return 0
    fi

    if run_healthcheck "${cfg}"; then
        reset_health_state "${cfg}"
        return 0
    fi

    failures=$(increment_state_value "${cfg}" "failure_count")
    threshold=$(effective_failure_threshold "${cfg}")
    set_state_value "${cfg}" "last_health_epoch" "${now}"
    log "Health check failed for '${display_name}' (${failures}/${threshold})"

    if [ "${failures}" -ge "${threshold}" ]; then
        stop_container "${cfg}" "${display_name}"
        schedule_restart "${cfg}" "${display_name}"
    fi
}

handle_stopped_container() {
    local cfg="$1"
    local display_name="$2"
    local now next_restart started_once
    now=$(date +%s 2>/dev/null || echo 0)
    started_once=$(numeric_or_default "$(get_state_value "${cfg}" "started_once")" "0")

    if is_supervision_enabled "${cfg}"; then
        next_restart=$(numeric_or_default "$(get_state_value "${cfg}" "next_restart_epoch")" "0")
        if [ "${next_restart}" -gt "${now}" ]; then
            return 0
        fi

        if start_container "${cfg}" "${display_name}" "supervised recovery"; then
            return 0
        fi

        schedule_restart "${cfg}" "${display_name}"
        return 0
    fi

    if [ "${started_once}" -eq 0 ]; then
        start_container "${cfg}" "${display_name}" "run_at_boot"
    fi
}

process_config() {
    local cfg="$1"
    local display_name
    display_name=$(get_display_name "${cfg}")

    if ! should_run_at_boot "${cfg}"; then
        return 0
    fi

    if is_container_running "${cfg}"; then
        if is_supervision_enabled "${cfg}"; then
            handle_running_container "${cfg}" "${display_name}"
        fi
    else
        handle_stopped_container "${cfg}" "${display_name}"
    fi
}

list_config_files() {
    bb find "${CONTAINERS_DIR}" -name "container.config" 2>/dev/null
}

process_boot_configs() {
    local cfg count
    count=0
    for cfg in $(list_config_files); do
        if [ -f "${cfg}" ] && should_run_at_boot "${cfg}"; then
            count=$((count + 1))
            process_config "${cfg}"
        fi
    done
    echo "${count}"
}

supervisor_iteration() {
    local cfg
    for cfg in $(list_config_files); do
        if [ -f "${cfg}" ] && should_run_at_boot "${cfg}"; then
            process_config "${cfg}"
        fi
    done
}

update_module_description() {
    local count="$1"
    if [ -f "${MODDIR}/module.prop" ]; then
        local string
        string="description=supervisor active: ${count} boot container(s) managed"
        bb sed -i "s/^description=.*/${string}/g" "${MODDIR}/module.prop" 2>/dev/null
    fi
}

wait_for_boot_completion() {
    log "Waiting for boot to complete..."
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
        sleep 1
    done

    log "Boot completed, waiting ${BOOT_WAIT_SECONDS} seconds for system stability..."
    sleep "${BOOT_WAIT_SECONDS}"
}

check_prerequisites() {
    if [ ! -f "${DROIDSPACE_BINARY}" ]; then
        log "ERROR: Droidspaces binary not found at ${DROIDSPACE_BINARY}"
        return 1
    fi

    if [ ! -f "${BUSYBOX_BINARY}" ] && ! command -v busybox >/dev/null 2>&1; then
        log "ERROR: Busybox binary not found at ${BUSYBOX_BINARY}"
        return 1
    fi

    return 0
}

prepare_environment() {
    mkdir -p "${LOGS_DIR}" "${STATE_DIR}" 2>/dev/null
    : > "${LOGS_FILE}" 2>/dev/null
    exec >> "${LOGS_FILE}" 2>&1

    log "Droidspaces boot supervisor started"
    log "Applying SELinux context to rootfs images..."
    bb find "${CONTAINERS_DIR}" -name "*.img" -exec chcon u:object_r:vold_data_file:s0 {} + 2>/dev/null
}

main() {
    prepare_environment

    if ! check_prerequisites; then
        exit 1
    fi

    log "All prerequisites checked successfully"
    wait_for_boot_completion

    local managed_count
    managed_count=$(process_boot_configs)
    log "Initial boot processing complete (${managed_count} run_at_boot container(s))"
    update_module_description "${managed_count}"

    while true; do
        supervisor_iteration
        sleep "${SUPERVISOR_SCAN_INTERVAL_SEC}"
    done
}

if [ "${DS_SERVICE_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
fi
