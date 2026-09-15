package com.terrydev.nearlink

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import java.net.InetAddress
import java.util.UUID

class NearbyDiscovery(context: Context, private val localDevice: NearbyDevice) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val multicastLock = context.applicationContext
        .getSystemService(WifiManager::class.java)
        .createMulticastLock("NearLinkDiscovery")
    private var localName = localDevice.name
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var onDevicesChanged: (List<NearbyDevice>) -> Unit = {}
    private var onStatusChanged: (String) -> Unit = {}
    private val devices = linkedMapOf<UUID, NearbyDevice>()

    fun start(onChanged: (List<NearbyDevice>) -> Unit, onStatus: (String) -> Unit = {}) {
        onDevicesChanged = onChanged
        onStatusChanged = onStatus
        multicastLock.setReferenceCounted(false)
        multicastLock.acquire()
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = localName
            serviceType = NearLinkProtocol.SERVICE_TYPE
            port = NearLinkProtocol.PORT
            setAttribute("deviceId", localDevice.id.toString())
            setAttribute("platform", localDevice.platform)
            setAttribute("protocolVersion", localDevice.protocolVersion.toString())
        }
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                localName = info.serviceName
                onStatusChanged("Advertising as ${info.serviceName}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                onStatusChanged("Could not advertise service ($errorCode)")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        nsd.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registration)

        discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                onStatusChanged("Searching nearby devices")
            }
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                onStatusChanged("Discovery failed ($errorCode)")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceName == localName) return
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        onStatusChanged("Could not resolve ${serviceInfo.serviceName} ($errorCode)")
                    }
                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        val advertisedID = serviceInfo.attributes["deviceId"]
                            ?.toString(Charsets.UTF_8)
                            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
                        val id = advertisedID ?: UUID.nameUUIDFromBytes(serviceInfo.serviceName.toByteArray())
                        if (id == localDevice.id) return
                        val host: InetAddress = serviceInfo.host ?: run {
                            onStatusChanged("Resolved ${serviceInfo.serviceName}, but no address was returned")
                            return
                        }
                        devices[id] = NearbyDevice(
                            id = id,
                            name = serviceInfo.serviceName,
                            platform = serviceInfo.attributes["platform"]
                                ?.toString(Charsets.UTF_8)
                                ?: inferPlatform(serviceInfo.serviceName),
                            host = host.hostAddress ?: return,
                            port = serviceInfo.port
                        )
                        onDevicesChanged(devices.values.sortedBy { it.name })
                        onStatusChanged("${devices.size} nearby device${if (devices.size == 1) "" else "s"}")
                    }
                })
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                val id = devices.entries.firstOrNull { it.value.name == info.serviceName }?.key
                    ?: UUID.nameUUIDFromBytes(info.serviceName.toByteArray())
                devices.remove(id)
                onDevicesChanged(devices.values.sortedBy { it.name })
            }
        }
        nsd.discoverServices(NearLinkProtocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    fun stop() {
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        registration?.let { runCatching { nsd.unregisterService(it) } }
        discovery = null
        registration = null
        devices.clear()
        if (multicastLock.isHeld) multicastLock.release()
    }

    /**
     * Android sometimes resolves a Bonjour service before its TXT attributes arrive.
     * In that case it initially uses a service-name-derived ID; replace it after the
     * peer verifies its real ID in the hello control frame.
     */
    fun reconcileDeviceID(verifiedID: UUID, remoteHost: String, advertisedName: String?): UUID? {
        val matchingEntry = devices.entries.firstOrNull { (_, device) ->
            normalizeHost(device.host) == normalizeHost(remoteHost) ||
                (!advertisedName.isNullOrBlank() && device.name == advertisedName)
        } ?: return null
        val provisionalID = matchingEntry.key
        if (provisionalID == verifiedID) return null

        val device = matchingEntry.value
        devices.remove(provisionalID)
        devices[verifiedID] = device.copy(id = verifiedID)
        onDevicesChanged(devices.values.sortedBy { it.name })
        return provisionalID
    }

    private fun normalizeHost(host: String): String =
        host.trim().removePrefix("[").removeSuffix("]").substringBefore('%')

    private fun inferPlatform(name: String): String {
        val normalized = name.lowercase()
        return when {
            normalized.startsWith("android-") || normalized.contains("android") -> "android"
            normalized.startsWith("windows-") || normalized.contains("windows") -> "windows"
            normalized.startsWith("mac") || normalized.contains("macbook") -> "macOS"
            normalized.startsWith("iphone") || normalized.contains("iphone") -> "iOS"
            else -> "unknown"
        }
    }
}
