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
	const out = execFileSync(
		"adb",
		[
			...(serial ? ["-s", serial] : []),
			"shell",
			"am",
			"broadcast",
			"-a",
			"dev.rhr.DEBUG_FAULT",
			"--es",
			"name",
			fault,
		],
		{ encoding: "utf8" },
	);
	// `am broadcast` exits 0 even when nothing received the intent, so read
	// the result it prints rather than trusting the exit code.
	if (!out.includes("result=0")) {
		throw new Error(
			`no receiver took "${fault}" — is a debug player running?\n${out.trim()}`,
		);
	}
	console.log(`fault: ${fault}`);
}
