package com.droidspaces.app.util

enum class ContainerWorkloadProfile(val configValue: String) {
    STANDARD("standard"),
    K3S_NODE("k3s_node");

    companion object {
        fun fromConfigValue(value: String?): ContainerWorkloadProfile {
            return when (value?.trim()?.lowercase()) {
                "k3s", "k3s-node", "k3s_node" -> K3S_NODE
                else -> STANDARD
            }
        }
    }
}

object ContainerWorkloadDefaults {
    const val K3S_SERVICE = "k3s"
    const val K3S_READY_URL = "https://127.0.0.1:6443/readyz"
    const val HEALTH_INTERVAL_SEC = 30
    const val FAILURE_THRESHOLD = 3
    const val INITIAL_BACKOFF_SEC = 5
    const val MAX_BACKOFF_SEC = 300
    const val DISK_PRESSURE_THRESHOLD_PERCENT = 90

    fun applyPreset(
        profile: ContainerWorkloadProfile,
        netMode: String,
        volatileMode: Boolean,
        runAtBoot: Boolean,
        blockNestedNs: Boolean,
        forceCgroupv1: Boolean,
        supervisionEnabled: Boolean
    ): ProfilePresetResult {
        return when (profile) {
            ContainerWorkloadProfile.K3S_NODE -> ProfilePresetResult(
                netMode = "host",
                volatileMode = false,
                runAtBoot = true,
                blockNestedNs = false,
                forceCgroupv1 = false,
                supervisionEnabled = true
            )
            ContainerWorkloadProfile.STANDARD -> ProfilePresetResult(
                netMode = netMode,
                volatileMode = volatileMode,
                runAtBoot = runAtBoot,
                blockNestedNs = blockNestedNs,
                forceCgroupv1 = forceCgroupv1,
                supervisionEnabled = supervisionEnabled
            )
        }
    }

    data class ProfilePresetResult(
        val netMode: String,
        val volatileMode: Boolean,
        val runAtBoot: Boolean,
        val blockNestedNs: Boolean,
        val forceCgroupv1: Boolean,
        val supervisionEnabled: Boolean
    )
}

object ContainerConfigCodec {
    fun toConfigContent(container: ContainerInfo): String = buildString {
        appendLine("# Droidspaces Container Configuration")
        appendLine("# Generated automatically")
        appendLine()
        appendLine("name=${container.name}")
        appendLine("hostname=${container.hostname}")
        appendLine("rootfs_path=${container.rootfsPath}")
        appendLine("net_mode=${container.netMode}")
        appendLine("disable_ipv6=${if (container.disableIPv6) "1" else "0"}")
        appendLine("enable_android_storage=${if (container.enableAndroidStorage) "1" else "0"}")
        appendLine("enable_hw_access=${if (container.enableHwAccess) "1" else "0"}")
        appendLine("enable_termux_x11=${if (container.enableTermuxX11) "1" else "0"}")
        appendLine("selinux_permissive=${if (container.selinuxPermissive) "1" else "0"}")
        appendLine("volatile_mode=${if (container.volatileMode) "1" else "0"}")
        appendLine("workload_profile=${container.workloadProfile.configValue}")
        appendLine("supervision_enabled=${if (container.supervisionEnabled) "1" else "0"}")

        if (container.bindMounts.isNotEmpty()) {
            appendLine("bind_mounts=${container.bindMounts.joinToString(",") { "${it.src}:${it.dest}" }}")
        }
        if (container.netMode == "nat" && container.upstreamInterfaces.isNotEmpty()) {
            appendLine("upstream_interfaces=${container.upstreamInterfaces.joinToString(",")}")
        }
        if (container.netMode == "nat" && container.portForwards.isNotEmpty()) {
            appendLine("port_forwards=${container.portForwards.joinToString(",") {
                val mapping = if (it.containerPort != null) "${it.hostPort}:${it.containerPort}" else it.hostPort
                "$mapping/${it.proto}"
            }}")
        }
        if (container.dnsServers.isNotEmpty()) {
            appendLine("dns_servers=${container.dnsServers}")
        }

        appendLine("run_at_boot=${if (container.runAtBoot) "1" else "0"}")
        appendLine("force_cgroupv1=${if (container.forceCgroupv1) "1" else "0"}")
        appendLine("block_nested_ns=${if (container.blockNestedNs) "1" else "0"}")

        if (container.workloadProfile == ContainerWorkloadProfile.K3S_NODE) {
            appendLine("healthcheck_type=k3s")
            appendLine("healthcheck_service=${ContainerWorkloadDefaults.K3S_SERVICE}")
            appendLine("healthcheck_url=${ContainerWorkloadDefaults.K3S_READY_URL}")
            appendLine("healthcheck_interval_sec=${ContainerWorkloadDefaults.HEALTH_INTERVAL_SEC}")
            appendLine("healthcheck_failures_before_restart=${ContainerWorkloadDefaults.FAILURE_THRESHOLD}")
            appendLine("restart_initial_backoff_sec=${ContainerWorkloadDefaults.INITIAL_BACKOFF_SEC}")
            appendLine("restart_max_backoff_sec=${ContainerWorkloadDefaults.MAX_BACKOFF_SEC}")
            appendLine("disk_pressure_threshold_percent=${ContainerWorkloadDefaults.DISK_PRESSURE_THRESHOLD_PERCENT}")
        }

        if (container.netMode == "nat" && container.staticNatIp.isNotEmpty()) {
            appendLine("static_nat_ip=${container.staticNatIp}")
        }
        appendLine("use_sparse_image=${if (container.useSparseImage) "1" else "0"}")
        if (container.sparseImageSizeGB != null) {
            appendLine("sparse_image_size_gb=${container.sparseImageSizeGB}")
        }
        if (container.envFileContent != null) {
            appendLine("env_file=${Constants.CONTAINERS_BASE_PATH}/${ContainerManager.sanitizeContainerName(container.name)}/.env")
        }
    }

    fun parseConfigContent(configContent: String, defaultName: String): ContainerInfo {
        val configMap = mutableMapOf<String, String>()

        configContent.lines().forEach { line ->
            val trimmed = line.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("#")) {
                return@forEach
            }

            val parts = trimmed.split("=", limit = 2)
            if (parts.size == 2) {
                configMap[parts[0].trim()] = parts[1].trim()
            }
        }

        val containerName = configMap["name"] ?: defaultName
        val useSparseImage = configMap["use_sparse_image"] == "1"
        val sparseImageSizeGB = configMap["sparse_image_size_gb"]?.toIntOrNull()
        val workloadProfile = ContainerWorkloadProfile.fromConfigValue(configMap["workload_profile"])

        val bindMounts = configMap["bind_mounts"]?.split(",")?.mapNotNull {
            val parts = it.split(":", limit = 2)
            if (parts.size == 2) BindMount(parts[0], parts[1]) else null
        } ?: emptyList()

        val upstreamInterfaces = configMap["upstream_interfaces"]
            ?.split(",")
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?: emptyList()

        val portForwards = configMap["port_forwards"]?.split(",")?.mapNotNull { pfStr ->
            try {
                val parts = pfStr.trim().split("/")
                val proto = if (parts.size > 1) parts[1].lowercase() else "tcp"
                val portParts = parts[0].split(":")
                if (portParts.size == 2) {
                    PortForward(portParts[0].trim(), portParts[1].trim(), proto)
                } else if (portParts.size == 1 && portParts[0].isNotBlank()) {
                    PortForward(portParts[0].trim(), null, proto)
                } else {
                    null
                }
            } catch (_: Exception) {
                null
            }
        } ?: emptyList()

        val supervisionEnabled = when (configMap["supervision_enabled"]) {
            "1" -> true
            "0" -> false
            else -> workloadProfile == ContainerWorkloadProfile.K3S_NODE
        }

        return ContainerInfo(
            name = containerName,
            hostname = configMap["hostname"] ?: containerName,
            rootfsPath = configMap["rootfs_path"] ?: if (useSparseImage) {
                ContainerManager.getSparseImagePath(containerName)
            } else {
                ContainerManager.getRootfsPath(containerName)
            },
            netMode = configMap["net_mode"] ?: "host",
            disableIPv6 = configMap["disable_ipv6"] == "1",
            enableAndroidStorage = configMap["enable_android_storage"] == "1",
            enableHwAccess = configMap["enable_hw_access"] == "1",
            enableTermuxX11 = configMap["enable_termux_x11"] == "1",
            selinuxPermissive = configMap["selinux_permissive"] == "1",
            volatileMode = configMap["volatile_mode"] == "1",
            bindMounts = bindMounts,
            dnsServers = configMap["dns_servers"] ?: "",
            runAtBoot = configMap["run_at_boot"] == "1",
            status = ContainerStatus.STOPPED,
            useSparseImage = useSparseImage,
            sparseImageSizeGB = sparseImageSizeGB,
            upstreamInterfaces = upstreamInterfaces,
            portForwards = portForwards,
            forceCgroupv1 = configMap["force_cgroupv1"] == "1",
            blockNestedNs = configMap["block_nested_ns"] == "1",
            staticNatIp = configMap["static_nat_ip"] ?: "",
            workloadProfile = workloadProfile,
            supervisionEnabled = supervisionEnabled
        )
    }
}
