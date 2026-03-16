package com.example.music_player4

import android.content.Context
import android.media.AudioManager
import android.os.SystemClock
import android.view.KeyEvent
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val CHANNEL = "media_controls"
    private val TAG = "MainActivity"
    private lateinit var audioManager: AudioManager

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result -> 
		    Log.d(TAG, "Received method call: ${call.method}")
			when (call.method) {
				"playPause" -> {
					val ok = playPause()
					Log.d(TAG, "playPause result: $ok")
					result.success(ok)
				}
				"next" -> {
					val ok = skipNext()
					Log.d(TAG, "skipNext result: $ok")
					result.success(ok)
				}
				"previous" -> {
					val ok = skipPrevious()
					Log.d(TAG, "skipPrevious result: $ok")
					result.success(ok)
				}
				"setVolume" -> {
					val level = call.argument<Double>("level") ?: 0.5
					val ok = setVolume(level)
					Log.d(TAG, "setVolume result: $ok")
					result.success(ok)
				}
				else -> {
				    Log.w(TAG, "Unknown method: ${call.method}")
				    result.notImplemented()
				}
			}
		}
	}

	private fun playPause(): Boolean {
	    return try {
	        // 发送播放/暂停按键事件
	        val eventTime = SystemClock.uptimeMillis()
	        val downEvent = KeyEvent(eventTime, eventTime, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, 0)
	        val upEvent = KeyEvent(eventTime, eventTime, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, 0)
	        
	        audioManager.dispatchMediaKeyEvent(downEvent)
	        audioManager.dispatchMediaKeyEvent(upEvent)
	        
	        Log.d(TAG, "Sent play/pause media key event")
	        true
	    } catch (e: Exception) {
	        Log.e(TAG, "Failed to send play/pause event", e)
	        false
	    }
	}

	private fun skipNext(): Boolean {
	    return try {
	        // 发送下一首按键事件
	        val eventTime = SystemClock.uptimeMillis()
	        val downEvent = KeyEvent(eventTime, eventTime, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_NEXT, 0)
	        val upEvent = KeyEvent(eventTime, eventTime, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_NEXT, 0)
	        
	        audioManager.dispatchMediaKeyEvent(downEvent)
	        audioManager.dispatchMediaKeyEvent(upEvent)
	        
	        Log.d(TAG, "Sent next media key event")
	        true
	    } catch (e: Exception) {
	        Log.e(TAG, "Failed to send next event", e)
	        false
	    }
	}

	private fun skipPrevious(): Boolean {
	    return try {
	        // 发送上一首按键事件
	        val eventTime = SystemClock.uptimeMillis()
	        val downEvent = KeyEvent(eventTime, eventTime, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PREVIOUS, 0)
	        val upEvent = KeyEvent(eventTime, eventTime, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PREVIOUS, 0)
	        
	        audioManager.dispatchMediaKeyEvent(downEvent)
	        audioManager.dispatchMediaKeyEvent(upEvent)
	        
	        Log.d(TAG, "Sent previous media key event")
	        true
	    } catch (e: Exception) {
	        Log.e(TAG, "Failed to send previous event", e)
	        false
	    }
	}

	private fun setVolume(level: Double): Boolean {
		return try {
			val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
			val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
			val vol = (level.coerceIn(0.0, 1.0) * max).toInt().coerceIn(0, max)
			audio.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0)
			Log.d(TAG, "Set volume to $vol (level: $level)")
			true
		} catch (e: Exception) {
			Log.e(TAG, "setVolume failed", e)
			false
		}
	}
}