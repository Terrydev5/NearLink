package com.terrydev.nearlink

import android.Manifest

/** Keep the existing startup permission policy, accepting approximate location.
 * NSD does not use coordinates; choosing approximate must not block startup.
 */
internal object NearbyPermissionPolicy {
    fun requestedPermissions(sdk: Int): Array<String> = if (sdk >= 33) {
        arrayOf("android.permission.NEARBY_WIFI_DEVICES")
    } else {
        // Android 12 can ignore fine-only requests. Always request the pair.
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    }

    fun canStart(sdk: Int, isGranted: (String) -> Boolean): Boolean =
        requestedPermissions(sdk).any(isGranted)
}
