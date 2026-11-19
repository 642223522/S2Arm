// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.StandardOpenOption;

/**
 * #528 item 15: did the last game session end abnormally? The Android side of iOS runtime/src/sesdiag.c.
 * The :game process marks files/s2a_session.mark "fg" while the game is in front and "bg" in the background.
 * When the player or the game ends the session it writes "end", and the native graceful shutdown deletes exactly
 * "end\n" at its last step (s2a_sesmark_clear_home in android/native/runtime/platform/lifecycle_android.c), so a
 * shutdown that fails or hangs still leaves a marker. The library reads it: "fg" or "end" means the session did not
 * finish (crash, killed while hung, out of memory, runtime error stop, failed shutdown). "bg" means it was closed or
 * reclaimed in the background, which is not abnormal. Pure Java so the host tests run it.
 */
final class LastSession {
    static final String FILE = "s2a_session.mark";
    /** ENDING ("end\n") is only ever written; read() reports it as FOREGROUND. The native side deletes exactly these bytes. */
    static final int NONE = 0, FOREGROUND = 1, BACKGROUND = 2, ENDING = 3;

    /** What a player-facing notice can say about an ApplicationExitInfo reason; NO_REASON says nothing. */
    static final int NO_REASON = -1, CRASH = 0, NATIVE_CRASH = 1, NOT_RESPONDING = 2, LOW_MEMORY = 3, SIGNALED = 4,
        EXCESSIVE_RESOURCES = 5;

    private LastSession() {}

    /** NONE without a marker; a marker that cannot be read in full counts as FOREGROUND (ask once more rather than miss a crash). */
    static int read(File dir) {
        byte[] head = new byte[2];
        int n = 0;
        try (InputStream in = Files.newInputStream(new File(dir, FILE).toPath())) {
            for (int r; n < head.length && (r = in.read(head, n, head.length - n)) > 0; ) n += r;
        } catch (NoSuchFileException gone) {
            return NONE;
        } catch (IOException | RuntimeException unreadable) {
            return FOREGROUND;
        }
        return n == 2 && head[0] == 'b' && head[1] == 'g' ? BACKGROUND : FOREGROUND;
    }

    /** NONE deletes the marker; FOREGROUND / BACKGROUND / ENDING rewrite it. */
    static void mark(File dir, int state) throws IOException {
        File file = new File(dir, FILE);
        if (state == NONE) {
            Files.deleteIfExists(file.toPath());
            return;
        }
        String text = state == BACKGROUND ? "bg\n" : state == ENDING ? "end\n" : "fg\n";
        Files.write(file.toPath(), text.getBytes(StandardCharsets.US_ASCII),
            StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE);
    }

    /** When the marker was last written (the session's last move to the foreground), 0 without one. */
    static long markedAt(File dir) {
        return new File(dir, FILE).lastModified();
    }

    /**
     * The exit record that ended the marked session: the newest record of the game process written at or after
     * the marker. -1 when there is none; an older record belongs to an earlier session and says nothing about this one.
     */
    static int pick(String gameProcess, long markedAt, String[] processes, long[] timestamps) {
        int best = -1;
        for (int i = 0; i < processes.length && i < timestamps.length; i++) {
            if (!gameProcess.equals(processes[i]) || timestamps[i] < markedAt) continue;
            if (best < 0 || timestamps[i] > timestamps[best]) best = i;
        }
        return best;
    }

    /** ApplicationExitInfo.REASON_* (values as in DiagnosticExits) to what the notice can say. Others say nothing. */
    static int kind(int reason) {
        switch (reason) {
            case 2: return SIGNALED;              // REASON_SIGNALED: status is the signal
            case 3: return LOW_MEMORY;            // REASON_LOW_MEMORY
            case 4: return CRASH;                 // REASON_CRASH (Java)
            case 5: return NATIVE_CRASH;          // REASON_CRASH_NATIVE: status is the signal
            case 6: return NOT_RESPONDING;        // REASON_ANR
            case 9: return EXCESSIVE_RESOURCES;   // REASON_EXCESSIVE_RESOURCE_USAGE
            default: return NO_REASON;
        }
    }

    /** HostApi stop reasons (NativeBridge.stopReason): only "exit requested" (0) is the game ending the session itself. */
    static boolean cleanStop(int hostStopReason) {
        return hostStopReason == 0;
    }
}
