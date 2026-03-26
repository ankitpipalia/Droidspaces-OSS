# Homelab K3s Node

Droidspaces now has a first-class `k3s_node` workload profile aimed at a single-node homelab container running on Android.

## What The Profile Does

When the Android app saves a container with the `K3s Node` profile, it writes:

- `workload_profile=k3s_node`
- `supervision_enabled=1`
- `healthcheck_type=k3s`
- `healthcheck_service=k3s`
- `healthcheck_url=https://127.0.0.1:6443/readyz`
- `healthcheck_interval_sec=30`
- `healthcheck_failures_before_restart=3`
- `restart_initial_backoff_sec=5`
- `restart_max_backoff_sec=300`
- `disk_pressure_threshold_percent=90`

The profile also applies appliance-style defaults in the UI:

- host networking
- persistent storage (`volatile_mode=0`)
- `run_at_boot=1`
- nested namespaces allowed (`block_nested_ns=0`)
- Cgroup v2 preference (`force_cgroupv1=0`)

## Boot Supervision

The boot module no longer exits after a single `start`.

It now:

1. waits for Android boot completion
2. starts all `run_at_boot=1` containers
3. keeps looping as a supervisor
4. performs workload-aware health checks
5. stops and restarts unhealthy supervised containers with exponential backoff

For `k3s_node`, health is defined as:

- container is still running
- `systemctl is-active k3s` succeeds
- API readiness passes on `https://127.0.0.1:6443/readyz` when `curl` or `wget` is available
- `/var/lib/rancher/k3s` is below the configured disk pressure threshold

## Current Scope

This is a first implementation focused on reliability of a single phone-hosted node.

Still intentionally out of scope:

- snapshots / rollback
- resource limits in the Android UI
- multi-node orchestration
- historical telemetry in the app
