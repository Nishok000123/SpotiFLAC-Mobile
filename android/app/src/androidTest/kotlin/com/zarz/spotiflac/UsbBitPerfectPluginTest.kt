package com.zarz.spotiflac

import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UsbBitPerfectPluginTest {
    @Test
    fun unsupportedRouteReturnsFallbackAndEngineDetachesCleanly() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val manager = context.getSystemService(AudioManager::class.java)
        assumeTrue(manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).none {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        })
        lateinit var engine: FlutterEngine
        lateinit var plugin: UsbBitPerfectPlugin
        instrumentation.runOnMainSync {
            engine = FlutterEngine(context)
            plugin = UsbBitPerfectPlugin()
            engine.plugins.add(plugin)
        }
        try {
            fun invoke(method: String, arguments: Map<String, Any>? = null): Any? {
                val done = CountDownLatch(1)
                var value: Any? = null
                var failure: String? = null
                instrumentation.runOnMainSync {
                    plugin.onMethodCall(MethodCall(method, arguments), object : MethodChannel.Result {
                        override fun success(result: Any?) { value = result; done.countDown() }
                        override fun error(code: String, message: String?, details: Any?) {
                            failure = "$code: $message"
                            done.countDown()
                        }
                        override fun notImplemented() { failure = "not implemented"; done.countDown() }
                    })
                }
                assertTrue("Native method timed out", done.await(10, TimeUnit.SECONDS))
                assertNull(failure)
                return value
            }
            val result = invoke("prepare", mapOf("path" to "/unopened.flac", "token" to 1)) as Map<*, *>
            assertEquals(if (android.os.Build.VERSION.SDK_INT >= 34) "no_usb" else "android_version", result["reason"])
            assertNull(result["ready"])
            invoke("stop")
        } finally {
            instrumentation.runOnMainSync { engine.destroy() }
        }
    }
}
