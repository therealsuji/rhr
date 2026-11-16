package dev.rhr.rhr_player

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AgentHandsTest {
	private fun sheet(pkg: String, button: String) =
		JSONArray("""[{"package":"$pkg","nodes":[{"text":"Update this app?","frame":[0,0.7,1,0.1],"children":[$button]}]}]""")

	@Test fun `finds the standard confirm button at its center`() {
		val button = AgentHands.installButton(
			sheet("com.google.android.packageinstaller", """{"text":"Bijwerken","id":"android:id/button1","frame":[0.5,0.9,0.4,0.04]}"""),
		)!!
		assertEquals(0.7, button.first, 1e-9)
		assertEquals(0.92, button.second, 1e-9)
	}

	@Test fun `falls back to the label on a sheet without the standard id`() {
		val button = AgentHands.installButton(
			sheet("com.samsung.android.packageinstaller", """{"text":"Update","frame":[0.5,0.9,0.4,0.04]}"""),
		)
		assertEquals(0.7, button!!.first, 1e-9)
	}

	@Test fun `waits while Android keeps the button disabled`() {
		assertNull(
			AgentHands.installButton(
				sheet("com.android.packageinstaller", """{"text":"Update","id":"android:id/button1","frame":[0,0,1,1],"flags":["disabled"]}"""),
			),
		)
	}

	@Test fun `never taps a button in another app`() {
		assertNull(
			AgentHands.installButton(
				sheet("com.example.bank", """{"text":"Install","id":"android:id/button1","frame":[0,0,1,1]}"""),
			),
		)
	}

	private fun playProtect(body: String) = JSONArray(
		"""[{"package":"com.android.vending","nodes":[{"text":"Google Play Protect","frame":[0,0.2,1,0.03]},$body,{"text":"Scan app","frame":[0,0.7,1,0.04]},{"text":"Don't install app","frame":[0,0.8,1,0.04]}]}]""",
	)

	@Test fun `opens Play Protect's details rather than scanning`() {
		val tap = AgentHands.playProtectStep(playProtect("""{"text":"More details","frame":[0.2,0.5,0.6,0.04]}"""))!!
		assertEquals(0.52, tap.second, 1e-9)
	}

	@Test fun `taps the install link on the last line of its text`() {
		val tap = AgentHands.playProtectStep(
			playProtect("""{"text":"The scan may take a while.\\n\\nInstall without scanning","frame":[0.1,0.5,0.8,0.1]}"""),
		)!!
		assertEquals(0.5, tap.first, 1e-9)
		assertEquals(0.588, tap.second, 1e-9)
	}

	@Test fun `leaves other Play Store screens alone`() {
		assertNull(
			AgentHands.playProtectStep(
				JSONArray("""[{"package":"com.android.vending","nodes":[{"text":"More details","frame":[0,0,1,1]}]}]"""),
			),
		)
	}
}
