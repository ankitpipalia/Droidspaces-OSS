#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SERVICE_SCRIPT="${REPO_ROOT}/Android/app/src/main/assets/boot-module/service.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

TEST_ROOT="${TMPDIR}/runtime"
CONTAINERS_DIR="${TEST_ROOT}/Containers"
STATE_DIR="${TEST_ROOT}/State"
MODDIR="${TMPDIR}/module"
FAKE_BIN="${TMPDIR}/fake-droidspaces.sh"
EVENT_LOG="${TMPDIR}/events.log"

mkdir -p "${CONTAINERS_DIR}/lab-node" "${STATE_DIR}" "${MODDIR}"

cat > "${CONTAINERS_DIR}/lab-node/container.config" <<'EOF'
name=lab-node
rootfs_path=/tmp/rootfs
run_at_boot=1
workload_profile=k3s_node
supervision_enabled=1
healthcheck_interval_sec=1
healthcheck_failures_before_restart=2
restart_initial_backoff_sec=2
restart_max_backoff_sec=4
EOF

cat > "${FAKE_BIN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

EVENT_LOG=${EVENT_LOG:?}
FAKE_RUNTIME_ROOT=${FAKE_RUNTIME_ROOT:?}

mkdir -p "${FAKE_RUNTIME_ROOT}"

cfg=""
name=""
args=("$@")
idx=0

while [ $idx -lt ${#args[@]} ]; do
    case "${args[$idx]}" in
        --config)
            idx=$((idx + 1))
            cfg="${args[$idx]}"
            ;;
        --name)
            idx=$((idx + 1))
            name="${args[$idx]}"
            ;;
        *)
            break
            ;;
    esac
    idx=$((idx + 1))
done

if [ -n "${cfg}" ] && [ -z "${name}" ]; then
    name=$(awk -F= '$1=="name"{print $2; exit}' "${cfg}")
fi

command_name="${args[$idx]}"

state_file="${FAKE_RUNTIME_ROOT}/${name}.state"
touch "${state_file}"

get_value() {
    local key="$1"
    awk -F= -v key="${key}" '$1==key{print $2; exit}' "${state_file}"
}

set_value() {
    local key="$1"
    local value="$2"
    local tmp="${state_file}.tmp"
    awk -F= -v key="${key}" '$1!=key{print}' "${state_file}" > "${tmp}" 2>/dev/null || true
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    mv "${tmp}" "${state_file}"
}

inc_value() {
    local key="$1"
    local current
    current=$(get_value "${key}")
    if [ -z "${current}" ]; then
        current=0
    fi
    current=$((current + 1))
    set_value "${key}" "${current}"
}

case "${command_name}" in
    start)
        echo "start:${name}" >> "${EVENT_LOG}"
        inc_value start_count
        set_value running 1
        set_value pid 4242
        exit 0
        ;;
    pid)
        if [ "$(get_value running)" = "1" ]; then
            echo "${name}" >/dev/null
            printf '%s\n' "$(get_value pid)"
        else
            printf 'NONE\n'
        fi
        ;;
    stop)
        echo "stop:${name}" >> "${EVENT_LOG}"
        inc_value stop_count
        set_value running 0
        exit 0
        ;;
    run)
        run_command="${args[$((idx + 1))]:-}"
        echo "run:${name}:${run_command}" >> "${EVENT_LOG}"
        if [ "$(get_value health)" = "fail" ]; then
            exit 1
        fi
        exit 0
        ;;
    *)
        echo "unexpected:${command_name}" >> "${EVENT_LOG}"
        exit 1
        ;;
esac
EOF
chmod +x "${FAKE_BIN}"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [ "${expected}" != "${actual}" ]; then
        printf 'ASSERTION FAILED: %s\nexpected=%s\nactual=%s\n' "${message}" "${expected}" "${actual}" >&2
        exit 1
    fi
}

get_fake_state() {
    local key="$1"
    awk -F= -v key="${key}" '$1==key{print $2; exit}' "${FAKE_RUNTIME_ROOT}/lab-node.state"
}

export DS_SERVICE_LIB_ONLY=1
export DROIDSPACE_DIR="${TEST_ROOT}"
export CONTAINERS_DIR
export STATE_DIR
export MODDIR
export DROIDSPACE_BINARY="${FAKE_BIN}"
export FAKE_RUNTIME_ROOT="${TMPDIR}/fake-runtime"
export EVENT_LOG

# shellcheck disable=SC1090
. "${SERVICE_SCRIPT}"
log() { :; }

managed_count=$(process_boot_configs)
assert_eq "1" "${managed_count}" "run_at_boot container count"
assert_eq "1" "$(get_fake_state start_count)" "container should start during boot processing"
assert_eq "1" "$(get_fake_state running)" "container should be running after boot processing"

set_value() {
    local cfg="$1"
    local key="$2"
    local value="$3"
    set_state_value "${cfg}" "${key}" "${value}"
}

CFG="${CONTAINERS_DIR}/lab-node/container.config"
set_value "${CFG}" "last_health_epoch" "0"
awk -F= '$1!="health"{print}' "${FAKE_RUNTIME_ROOT}/lab-node.state" > "${FAKE_RUNTIME_ROOT}/lab-node.state.tmp"
printf 'health=fail\n' >> "${FAKE_RUNTIME_ROOT}/lab-node.state.tmp"
mv "${FAKE_RUNTIME_ROOT}/lab-node.state.tmp" "${FAKE_RUNTIME_ROOT}/lab-node.state"

supervisor_iteration
assert_eq "1" "$(get_state_value "${CFG}" "failure_count")" "first failed health check should increment failure count"
assert_eq "1" "$(get_fake_state running)" "container should keep running until the failure threshold is reached"

set_value "${CFG}" "last_health_epoch" "0"
supervisor_iteration
assert_eq "0" "$(get_fake_state running)" "container should be stopped after consecutive health failures"
assert_eq "1" "$(get_fake_state stop_count)" "supervisor should stop the unhealthy container"
assert_eq "1" "$(get_state_value "${CFG}" "restart_count")" "restart count should increment after unhealthy restart scheduling"
assert_eq "4" "$(get_state_value "${CFG}" "restart_backoff_sec")" "restart backoff should double and clamp to max"

supervisor_iteration
assert_eq "1" "$(get_fake_state start_count)" "container must not restart before the backoff expires"

sleep 2
awk -F= '$1!="health"{print}' "${FAKE_RUNTIME_ROOT}/lab-node.state" > "${FAKE_RUNTIME_ROOT}/lab-node.state.tmp"
mv "${FAKE_RUNTIME_ROOT}/lab-node.state.tmp" "${FAKE_RUNTIME_ROOT}/lab-node.state"
supervisor_iteration
assert_eq "2" "$(get_fake_state start_count)" "container should restart after the backoff expires"
assert_eq "1" "$(get_fake_state running)" "container should be running again after supervised restart"
assert_eq "0" "$(get_state_value "${CFG}" "failure_count")" "successful restart should reset failure count"

printf 'boot supervisor tests passed\n'
