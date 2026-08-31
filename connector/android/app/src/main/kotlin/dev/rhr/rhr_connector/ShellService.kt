package dev.rhr.rhr_connector

import java.io.File

/**
 * Implementation of IShellService that Shizuku runs inside its server
 * process (uid shell). All it does is exec logcat/pidof and return text —
 * the connector polls `dumpLogcat` until the engine's VM service line
 * shows up.
 */
class ShellService : IShellService.Stub() {
	override fun dumpLogcat(pid: Int): String {
		val proc = Runtime.getRuntime()
			.exec(arrayOf("logcat", "-d", "-v", "brief", "--pid=$pid"))
		val out = proc.inputStream.bufferedReader().readText()
		proc.waitFor()
		return out
	}

	override fun pidof(pkg: String): String {
		val proc = Runtime.getRuntime().exec(arrayOf("pidof", pkg))
		val out = proc.inputStream.bufferedReader().readText().trim()
		proc.waitFor()
		return out
	}

	override fun forceStop(pkg: String) {
		val proc = Runtime.getRuntime().exec(arrayOf("am", "force-stop", pkg))
		proc.waitFor()
	}

	override fun setLogBufferSize(size: String) {
		val proc = Runtime.getRuntime().exec(arrayOf("logcat", "-G", size))
		proc.waitFor()
	}
}
