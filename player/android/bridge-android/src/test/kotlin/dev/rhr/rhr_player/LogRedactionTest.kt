package dev.rhr.rhr_player

import org.junit.Assert.assertEquals
import org.junit.Test

class LogRedactionTest {
	@Test
	fun `session codes keep only a prefix`() {
		assertEquals("rhr-abcd…", LogRedaction.session("rhr-abcd-efgh-jkmn"))
		assertEquals("dev-AbCd…", LogRedaction.session("dev-AbCdEfGhIjKlMnOpQrStUv"))
		assertEquals("…", LogRedaction.session("short"))
	}

	@Test
	fun `vm uris lose their auth token`() {
		assertEquals(
			"http://127.0.0.1:41235/…",
			LogRedaction.vmUri("http://127.0.0.1:41235/Xy9_tok3n=/"))
		assertEquals("…", LogRedaction.vmUri("not a uri"))
	}
}
