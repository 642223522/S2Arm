package org.s2arm.android;

/** Npad bit order and signed stick range, matching InputPump / s2a_vpad_read. */
final class GamepadState {
    /**
     * Face-button layout, same choice and values as iOS / Mac padFace (runtime/src/pad.c s2a_pad_layout_parse,
     * launchers/shared/game_settings.v1.json): auto follows the printed letters, switch puts Switch A on the right
     * button, xbox puts it on the bottom button. Android key codes are positional on every controller (AOSP key
     * layouts map a Nintendo pad's bottom "B" to BUTTON_A), so auto means Switch layout on Nintendo pads and Xbox
     * layout on everything else (Xbox, PlayStation where x confirms, unknown). Older Android values stay accepted:
     * position = switch, label = xbox.
     */
    static final int FACE_AUTO = 0, FACE_SWITCH = 1, FACE_XBOX = 2;
    private int face = FACE_AUTO;
    private boolean nintendo;
    private int keys;
    private int hat;
    private int triggers;
    private int lx, ly, rx, ry;

    /** Strict (intent extras): auto / switch / xbox, or the older position / label; anything else is -1. */
    static int parseFace(String mode) {
        if ("auto".equals(mode)) return FACE_AUTO;
        if ("switch".equals(mode) || "position".equals(mode)) return FACE_SWITCH;
        if ("xbox".equals(mode) || "label".equals(mode)) return FACE_XBOX;
        return -1;
    }
    static String faceName(int face) { return face == FACE_SWITCH ? "switch" : face == FACE_XBOX ? "xbox" : "auto"; }

    void setMapping(String mode) {
        int parsed = parseFace(mode);
        if (parsed < 0) throw new IllegalArgumentException("s2arm.gamemap must be auto, switch or xbox (or position / label): " + mode);
        face = parsed;
    }
    int face() { return face; }

    /** The controller now driving input is a Nintendo pad (decides what auto means). */
    void setNintendo(boolean value) { nintendo = value; }

    /**
     * Same test as pad.c s2a_pad_kind for Nintendo: Nintendo's USB vendor id (also used by Switch-mode third-party
     * pads), or the name fragments Apple's category strings carry (any case).
     */
    static boolean nintendo(int vendorId, String name) {
        if (vendorId == 0x057e) return true;
        if (name == null) return false;
        String n = name.toLowerCase(java.util.Locale.ROOT);
        return n.contains("nintendo") || n.contains("switch") || n.contains("joy-con") || n.contains("joycon");
    }

    void button(int bit, boolean down) {
        if (down) keys |= 1 << bit;
        else keys &= ~(1 << bit);
    }

    private static int axis(float value, float deadzone) {
        if (!Float.isFinite(value) || Math.abs(value) <= deadzone) return 0;
        return Math.round(Math.max(-1f, Math.min(1f, value)) * 32767f);
    }

    void motion(float x, float y, float z, float rz, float hatX, float hatY,
                float leftTrigger, float rightTrigger, float deadzone) {
        lx = axis(x, deadzone); ly = axis(-y, deadzone);
        rx = axis(z, deadzone); ry = axis(-rz, deadzone);
        hat = (hatX < -0.5f ? 1 << 12 : hatX > 0.5f ? 1 << 14 : 0)
            | (hatY < -0.5f ? 1 << 13 : hatY > 0.5f ? 1 << 15 : 0);
        triggers = (leftTrigger > 0.5f ? 1 << 8 : 0)
            | (rightTrigger > 0.5f ? 1 << 9 : 0);
    }

    void reset() { keys = hat = triggers = lx = ly = rx = ry = 0; }
    int buttons() {
        // Keep physical key state in positional order so changing modes while held cannot
        // leave the old mapped button stuck when its key-up event arrives.
        boolean xbox = face == FACE_XBOX || (face == FACE_AUTO && !nintendo);
        int mapped = xbox ? (keys & ~15) | ((keys & 5) << 1) | ((keys & 10) >> 1) : keys;
        return mapped | hat | triggers;
    }
    int leftX() { return lx; }
    int leftY() { return ly; }
    int rightX() { return rx; }
    int rightY() { return ry; }
}

