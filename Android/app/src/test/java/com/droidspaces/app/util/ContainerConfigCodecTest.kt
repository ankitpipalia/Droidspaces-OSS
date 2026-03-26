package com.droidspaces.app.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContainerConfigCodecTest {

    @Test
    fun `k3s profile serializes homelab defaults`() {
        val container = ContainerInfo(
            name = "lab-node",
            hostname = "lab-node",
            rootfsPath = "/data/local/Droidspaces/Containers/lab-node/rootfs",
            runAtBoot = true,
            workloadProfile = ContainerWorkloadProfile.K3S_NODE,
            supervisionEnabled = true
        )

        val config = ContainerConfigCodec.toConfigContent(container)

        assertTrue(config.contains("workload_profile=k3s_node"))
        assertTrue(config.contains("supervision_enabled=1"))
        assertTrue(config.contains("healthcheck_type=k3s"))
        assertTrue(config.contains("healthcheck_service=${ContainerWorkloadDefaults.K3S_SERVICE}"))
        assertTrue(config.contains("healthcheck_url=${ContainerWorkloadDefaults.K3S_READY_URL}"))
        assertTrue(config.contains("restart_initial_backoff_sec=${ContainerWorkloadDefaults.INITIAL_BACKOFF_SEC}"))
    }

    @Test
    fun `parser restores k3s profile metadata`() {
        val config = """
            name=lab-node
            hostname=lab-node
            rootfs_path=/data/local/Droidspaces/Containers/lab-node/rootfs
            net_mode=host
            run_at_boot=1
            workload_profile=k3s_node
            supervision_enabled=1
            force_cgroupv1=0
            block_nested_ns=0
        """.trimIndent()

        val parsed = ContainerConfigCodec.parseConfigContent(config, "fallback")

        assertEquals("lab-node", parsed.name)
        assertEquals(ContainerWorkloadProfile.K3S_NODE, parsed.workloadProfile)
        assertTrue(parsed.runAtBoot)
        assertTrue(parsed.supervisionEnabled)
    }

    @Test
    fun `parser defaults supervision for k3s profile when explicit flag is absent`() {
        val config = """
            name=lab-node
            hostname=lab-node
            rootfs_path=/tmp/rootfs
            workload_profile=k3s_node
        """.trimIndent()

        val parsed = ContainerConfigCodec.parseConfigContent(config, "fallback")

        assertEquals(ContainerWorkloadProfile.K3S_NODE, parsed.workloadProfile)
        assertTrue(parsed.supervisionEnabled)
    }

    @Test
    fun `k3s preset applies appliance-friendly defaults`() {
        val preset = ContainerWorkloadDefaults.applyPreset(
            profile = ContainerWorkloadProfile.K3S_NODE,
            netMode = "nat",
            volatileMode = true,
            runAtBoot = false,
            blockNestedNs = true,
            forceCgroupv1 = true,
            supervisionEnabled = false
        )

        assertEquals("host", preset.netMode)
        assertFalse(preset.volatileMode)
        assertTrue(preset.runAtBoot)
        assertFalse(preset.blockNestedNs)
        assertFalse(preset.forceCgroupv1)
        assertTrue(preset.supervisionEnabled)
    }
}
