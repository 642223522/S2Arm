package org.s2arm.android;

public final class GamepadStateTest {
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Gamepad state mismatch");
    }
    // Android key codes are positional: BUTTON_A = bottom, B = right, X = left, Y = top on every pad.
    // MainActivity turns them into the Switch-position bits 1 / 0 / 3 / 2 (bottom = Switch B ...).
    private static final int[] BOTTOM_RIGHT_LEFT_TOP = {1, 0, 3, 2};
    private static final int A = 1, B = 2, X = 4, Y = 8;
    private static int press(GamepadState pad, int bit) {
        pad.button(bit, true);
        int result = pad.buttons();
        pad.button(bit, false);
        check(pad.buttons() == 0);
        return result;
    }
    private static void expect(GamepadState pad, int bottom, int right, int left, int top) {
        int[] want = {bottom, right, left, top};
        for (int i = 0; i < 4; i++) check(press(pad, BOTTOM_RIGHT_LEFT_TOP[i]) == want[i]);
    }

    /** padFace (pad.c s2a_pad_layout_parse / s2a_pad_abxy_order), worked out from where the buttons sit. */
    private static void faceLayout() {
        GamepadState pad = new GamepadState();
        // Xbox / PlayStation / unknown pads under auto: letters are Xbox's (A bottom, B right, X left, Y top; PS x bottom).
        expect(pad, A, B, X, Y);
        // Nintendo pads under auto: printed letters are Switch's (A right, B bottom, X top, Y left).
        pad.setNintendo(true);
        expect(pad, B, A, Y, X);
        // switch: Switch positions whatever the pad.
        pad.setMapping("switch");
        expect(pad, B, A, Y, X);
        pad.setNintendo(false);
        expect(pad, B, A, Y, X);
        // xbox: Xbox positions whatever the pad.
        pad.setMapping("xbox");
        expect(pad, A, B, X, Y);
        pad.setNintendo(true);
        expect(pad, A, B, X, Y);
        // Older Android values keep their meaning.
        pad.setMapping("position"); check(pad.face() == GamepadState.FACE_SWITCH);
        pad.setMapping("label"); check(pad.face() == GamepadState.FACE_XBOX);
        pad.setMapping("auto"); check(pad.face() == GamepadState.FACE_AUTO);
        // Negative control: same pad, auto vs switch differ on a non-Nintendo pad (the test can see a wrong default).
        pad.setNintendo(false);
        check(press(pad, BOTTOM_RIGHT_LEFT_TOP[0]) == A);
        pad.setMapping("switch");
        check(press(pad, BOTTOM_RIGHT_LEFT_TOP[0]) == B);
        // Changing the pad kind while a face key is held must not leave a mapped bit stuck on release.
        pad.setMapping("auto");
        pad.button(1, true); check(pad.buttons() == A);
        pad.setNintendo(true); check(pad.buttons() == B);
        pad.button(1, false); check(pad.buttons() == 0);
        // Kind detection (pad.c s2a_pad_kind): Nintendo vendor id or name fragments, any case.
        check(GamepadState.nintendo(0x057e, "Wireless Gamepad"));
        check(GamepadState.nintendo(0x2dc8, "8BitDo Pro 2 for Nintendo Switch"));
        check(GamepadState.nintendo(0, "Joy-Con (L)"));
        check(GamepadState.nintendo(0, "JOYCON pair"));
        check(!GamepadState.nintendo(0x045e, "Xbox Wireless Controller"));
        check(!GamepadState.nintendo(0x054c, "DualSense Wireless Controller"));
        check(!GamepadState.nintendo(0x054c, null));
        for (String bad : new String[] {null, "", "Switch", "XBOX", "letter", "auto "}) check(GamepadState.parseFace(bad) == -1);
        check(GamepadState.faceName(GamepadState.parseFace("position")).equals("switch"));
        check(GamepadState.faceName(GamepadState.parseFace("label")).equals("xbox"));
    }

    public static void main(String[] args) {
        GamepadState pad = new GamepadState();
        check(pad.face() == GamepadState.FACE_AUTO);   // padFace default, as iOS / Mac
        pad.setMapping("switch");
        pad.button(0, true); pad.button(6, true);
        pad.motion(0.05f, -1f, 2f, Float.NaN, -1f, 1f, 1f, 0f, 0.15f);
        check(pad.leftX() == 0 && pad.leftY() == 32767);
        check(pad.rightX() == 32767 && pad.rightY() == 0);
        check(pad.buttons() == ((1 << 0) | (1 << 6) | (1 << 8) | (1 << 12) | (1 << 15)));
        // Releasing a key must not clear an independently held hat or trigger.
        pad.button(12, true); pad.button(12, false);
        check((pad.buttons() & (1 << 12)) != 0);
        pad.motion(0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0.15f);
        check(pad.buttons() == ((1 << 0) | (1 << 6)));
        pad.reset();
        check(pad.buttons() == 0 && pad.leftX() == 0 && pad.leftY() == 0
            && pad.rightX() == 0 && pad.rightY() == 0);

        // MainActivity passes Android A/B/X/Y as positional Npad bits 1/0/3/2.
        int[] faceBits = {1, 0, 3, 2};
        for (int bit : faceBits) {
            pad.button(bit, true); check(pad.buttons() == 1 << bit);
            pad.button(bit, false); check(pad.buttons() == 0);
        }
        pad.setMapping("label");
        for (int i = 0; i < faceBits.length; i++) {
            pad.button(faceBits[i], true); check(pad.buttons() == 1 << i);
            pad.button(faceBits[i], false); check(pad.buttons() == 0);
        }
        for (int bit = 4; bit < 16; bit++) {
            pad.button(bit, true); check(pad.buttons() == 1 << bit);
            pad.button(bit, false); check(pad.buttons() == 0);
        }
        pad.button(1, true); pad.button(3, true); pad.button(6, true);
        pad.motion(-1f, 1f, 1f, -1f, -1f, 0f, 0f, 1f, 0.15f);
        check(pad.buttons() == (1 | 4 | 64 | 512 | 4096));
        check(pad.leftX() == -32767 && pad.leftY() == -32767
            && pad.rightX() == 32767 && pad.rightY() == 32767);
        pad.setMapping("position");
        check(pad.buttons() == (2 | 8 | 64 | 512 | 4096));
        pad.setMapping("label");
        pad.button(1, false); pad.button(3, false);
        check(pad.buttons() == (64 | 512 | 4096));
        pad.reset();
        pad.button(1, true); check(pad.buttons() == 1); // focus reset retains mapping
        pad.setMapping("label"); check(pad.buttons() == 1); // repeated request retains held keys
        for (String invalid : new String[] {null, "", "labels", "LABEL", " label", "position "}) {
            try {
                pad.setMapping(invalid);
                throw new AssertionError("Invalid mapping accepted: " + invalid);
            } catch (IllegalArgumentException expected) {
                check(pad.buttons() == 1);
            }
        }
        pad.setMapping("position");
        pad.button(1, false); check(pad.buttons() == 0);
        faceLayout();
        System.out.println("Android gamepad: Npad mapping, padFace auto/switch/xbox, axis direction, clamping, independent sources, reset passed");
    }
}
