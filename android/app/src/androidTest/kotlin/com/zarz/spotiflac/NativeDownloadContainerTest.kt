package com.zarz.spotiflac

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeDownloadContainerTest {
    @Test
    fun misnamedMp4IsTaggedAndPublishedAsM4aWithoutOverwritingExistingAudio() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "container-test-${System.nanoTime()}").apply { mkdirs() }
        try {
            val input = File(root, "track.flac")
            val existing = File(root, "track.m4a").apply { writeText("existing download") }
            val fixture = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=44100",
                "-t", "0.2", "-c:a", "aac", "-f", "mp4", input.path,
            ))
            assertTrue(fixture.second, fixture.first)
            assertTrue(isMP4ContainerFile(input.path))
            val request = JSONObject()
                .put("contract_version", 1).put("item_id", "example-track")
                .put("service", "example-provider").put("track_name", "Container test")
                .put("artist_name", "Example artist").put("album_name", "Example album")
                .put("quality", "LOSSLESS").put("storage_mode", "app")
                .put("output_ext", ".flac").put("embed_metadata", true)
            val result = NativeDownloadFinalizer.finalize(
                context, "example-track", request.toString(), "{}",
                JSONObject().put("success", true).put("file_path", input.path)
                    .put("file_name", input.name),
                "{\"save_download_history\":false}",
            )
            assertTrue(result.toString(), result.getBoolean("success"))
            assertTrue(result.getBoolean("native_finalized"))
            val output = File(result.getString("file_path"))
            assertEquals("m4a", output.extension)
            assertTrue(output.length() > 0)
            assertTrue(isMP4ContainerFile(output.path))
            assertFalse(input.exists())
            assertEquals("existing download", existing.readText())
            val probe = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                "-hide_banner", "-i", output.path, "-map", "0:a:0", "-f", "null", "-",
            ))
            assertTrue(probe.second, probe.first)
            assertTrue(probe.second, probe.second.contains("Container test"))
            assertTrue(probe.second, probe.second.contains("Audio: aac"))
        } finally {
            root.deleteRecursively()
        }
    }
}
