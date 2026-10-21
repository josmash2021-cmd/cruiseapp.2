package com.cruiseinride.app

import android.content.Intent
import android.net.Uri
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var referralChannel: MethodChannel? = null

    companion object {
        @Volatile
        private var latestDriverCode: String? = null

        // Backend host (serves /drive today) + the brand domain (redirects
        // to it). Both are in the Manifest's App Links filters.
        private val REFERRAL_HOSTS = setOf(
            "cruiseapp2-production.up.railway.app",
            "cruiseinride.com",
            "www.cruiseinride.com",
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        referralChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "cruise/referral_link",
        )
        referralChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getPendingDriverCode") {
                result.success(latestDriverCode)
            } else {
                result.notImplemented()
            }
        }
        captureDriverReferralIntent(intent)
        readPlayInstallReferrer()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureDriverReferralIntent(intent)
    }

    private fun captureDriverReferralIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "https" ||
            uri.host !in REFERRAL_HOSTS
        ) return
        val path = uri.path ?: return
        if (!path.startsWith("/drive/")) return
        val code = path.removePrefix("/drive/")
            .substringBefore('/')
            .uppercase()
        if (code.isEmpty()) return
        latestDriverCode = code
        referralChannel?.invokeMethod("driverReferralLink", code)
    }

    private fun readPlayInstallReferrer() {
        val client = InstallReferrerClient.newBuilder(this).build()
        client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                if (responseCode ==
                    InstallReferrerClient.InstallReferrerResponse.OK
                ) {
                    try {
                        val referrer = client.installReferrer.installReferrer ?: ""
                        if (referrer.isNotEmpty()) {
                            val parsed = Uri.parse("https://cruiseinride.app/?$referrer")
                            val code = parsed.getQueryParameter("driver_code")
                                ?.uppercase()
                            if (!code.isNullOrEmpty()) {
                                latestDriverCode = code
                                referralChannel?.invokeMethod("driverReferralLink", code)
                            }
                        }
                    } catch (e: Exception) {
                        android.util.Log.w("ReferralLink", "install referrer read failed", e)
                    } finally {
                        client.endConnection()
                    }
                } else {
                    client.endConnection()
                }
            }

            override fun onInstallReferrerServiceDisconnected() = Unit
        })
    }
}
