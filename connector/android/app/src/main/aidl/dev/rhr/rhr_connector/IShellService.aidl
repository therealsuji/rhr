package dev.rhr.rhr_connector;

// Runs inside the Shizuku server process (uid shell) via bindUserService.
// Every Flutter debug engine prints its VM service door to its own log;
// shell can read ANY process's log — the one power the connector needs.
interface IShellService {
    /** Full recent logcat buffer of one process, filtered by its pid. */
    String dumpLogcat(int pid);

    /** `pidof <package>` for the target app. */
    String pidof(String pkg);

    /** Stops the target app so a fresh engine (and a fresh VM service
     *  log line) is produced on the next launch. */
    void forceStop(String pkg);

    /** `logcat -G <size>` — enlarges the ring buffer so a fresh VM service
     *  line survives rotation long enough to be discovered. */
    void setLogBufferSize(String size);
}
