// Sends one QA fault to the player over adb, named by RHR_FAULT.
//
// The same faults are reachable by tapping the lobby footer seven times, and
// that is how a person uses them. A flow should not: all seven taps have to
// land to count, nothing on screen reports how many did, and a run that
// loses one ends up on a screen it cannot describe. The first recording of
// qa-update-banners failed exactly that way as soon as its services were
// cold, which is what the broadcast replaces.
//
// Fault names are the ones RhrSessionService.debugInjectFault accepts.

import { execFileSync } from "node:child_process";

export function injectFault(fault, serial = process.env.RHR_DEVICE) {
	const device = serial ? ["-s", serial] : [];
	const adb = (args) => execFileSync("adb", [...device, ...args], { encoding: "utf8" });

	// How many times this fault has been seen already. `logcat -c` is not
	// used to isolate the new line: clearing races successive injections and
	// can wipe the very line being waited for.
	const marker = `fault from broadcast: ${fault}`;
	const count = (text) => text.split(marker).length - 1;
	const before = count(adb(["logcat", "-d", "-s", "rhr_debug_fault:I"]));

	adb(["shell", "am", "broadcast", "-a", "dev.rhr.DEBUG_FAULT", "--es", "name", fault]);

	// `am broadcast` prints "result=0" whether or not anything received the
	// intent — that is just the default result code, and an unregistered
	// receiver looks identical to a live one. Trusting it let a QA flow
	// inject nothing and still go green, which is worse than failing. The
	// receiver's own log line only exists when the receiver actually ran.
	// logcat lags the broadcast by a few tens of milliseconds, so look more
	// than once before concluding nothing received it.
	let seen = false;
	for (let attempt = 0; attempt < 20 && !seen; attempt++) {
		seen = count(adb(["logcat", "-d", "-s", "rhr_debug_fault:I"])) > before;
		if (!seen) execFileSync("sleep", ["0.1"]);
	}
	if (!seen) {
		throw new Error(
			`"${fault}" reached no receiver — is a DEBUG player running, and ` +
				`is it built from a tree that knows this fault? (an over-the-wire ` +
				`player update can replace the instrumented build)`,
		);
	}
	console.log(`fault: ${fault}`);
}
