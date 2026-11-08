package org.s2arm.android;

import java.util.function.Consumer;

/** Main-thread policy shared by activity lifecycle and platform focus callbacks. */
final class AudioFocusPolicy {
    static void focusChange(Consumer<Boolean> change, boolean gain, boolean canDuck) {
        if (gain) change.accept(true);
        else if (!canDuck) change.accept(false);
    }
    interface Backend {
        boolean request(Consumer<Boolean> change);
        void abandon();
    }
    private final Backend backend;
    private final Consumer<Boolean> output;
    private boolean active;
    private int generation;

    AudioFocusPolicy(Backend backend, Consumer<Boolean> output) {
        this.backend = backend;
        this.output = output;
        output.accept(false);
    }
    void resume() {
        if (active) return;
        active = true;
        int token = ++generation;
        output.accept(false);
        boolean granted = backend.request(allowed -> {
            if (active && generation == token) output.accept(allowed);
        });
        if (!granted) { ++generation; output.accept(false); }
        else if (active && generation == token) output.accept(true);
    }
    void pause() {
        if (!active) return;
        active = false;
        ++generation;
        output.accept(false);
        backend.abandon();
    }
}
