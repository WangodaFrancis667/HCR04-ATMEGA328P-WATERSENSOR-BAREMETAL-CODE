package com.example.client

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
	private val REQUEST_BLUETOOTH_PERMISSIONS = 1001

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)

		// On Android 12+ (API 31+) we must request BLUETOOTH_CONNECT and BLUETOOTH_SCAN at runtime.
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
			val needed = mutableListOf<String>()
			if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
				needed.add(Manifest.permission.BLUETOOTH_CONNECT)
			}
			if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
				needed.add(Manifest.permission.BLUETOOTH_SCAN)
			}

			if (needed.isNotEmpty()) {
				ActivityCompat.requestPermissions(this, needed.toTypedArray(), REQUEST_BLUETOOTH_PERMISSIONS)
			}
		}
	}
}
