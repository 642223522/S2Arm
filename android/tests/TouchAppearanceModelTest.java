// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

/** Pure model checks, runnable with Json.java and TouchLayout.java on a host JDK. */
public final class TouchAppearanceModelTest {
    private static int checks;
    private static void same(double expected, double actual) {
        checks++;
        if (Math.abs(expected - actual) > 1e-10)
            throw new AssertionError("expected " + expected + ", got " + actual);
    }
    private static TouchPad.Control control(TouchPad pad, String id) {
        for (TouchPad.Control c : pad.controls()) if (c.id.equals(id)) return c;
        throw new AssertionError("missing control " + id);
    }
    private static void padEdits() {
        TouchPad pad = new TouchPad();
        pad.layout(0, 0, 1920, 1080);
        for (String id : new String[] {"A", "DPAD", "left"}) {
            TouchPad.Control c = control(pad, id);
            pad.moveControl(c, c.x - 12, c.y - 10);
        }
        TouchLayout dragged = pad.editedLayout("mine", "Mine");
        TouchLayout resized = dragged.withButtonScale(1.25);
        pad.setLayout(resized);
        pad.layout(0, 0, 1920, 1080);
        TouchLayout saved = pad.editedLayout("mine", "Mine");
        for (TouchLayout.Button b : dragged.buttons) {
            same(b.x, saved.button(b.id).x); same(b.y, saved.button(b.id).y);
            same(b.width * 1.25, saved.button(b.id).width);
        }
        same(dragged.stick("left").activation.x, saved.stick("left").activation.x);
        same(dragged.stick("left").activation.y, saved.stick("left").activation.y);
        TouchPad.Control a = control(pad, "A");
        float px = a.x + a.halfWidth * 1.1f;
        checks++;
        if (!a.hit(px, a.y)) throw new AssertionError("resized hit region did not grow");
        pad.setLayout(dragged);
        pad.layout(0, 0, 1920, 1080);
        a = control(pad, "A");
        checks++;
        if (a.hit(px, a.y)) throw new AssertionError("unscaled hit region unexpectedly covers enlarged edge");
        pad.setLayout(saved);
        pad.layout(0, 0, 1080, 1920);
        // Portrait projection may clamp screen centres; saved normalized model must not drift.
        for (TouchLayout.Button b : saved.buttons) {
            same(b.width, pad.layoutModel().button(b.id).width);
            same(b.x, pad.layoutModel().button(b.id).x);
        }
    }
    public static void main(String[] args) {
        TouchLayout original = TouchLayout.androidDefault(1920, 1080);
        TouchLayout scaled = original.withButtonScale(1.25);
        for (TouchLayout.Button b : original.buttons) {
            TouchLayout.Button out = scaled.button(b.id);
            same(b.x, out.x); same(b.y, out.y);
            same(b.width * 1.25, out.width); same(b.height * 1.25, out.height);
            same(b.cornerRadius * 1.25, out.cornerRadius);
        }
        for (TouchLayout.Stick stick : original.sticks) {
            TouchLayout.Stick out = scaled.stick(stick.id);
            same(stick.radius, out.radius);
            same(stick.activation.x, out.activation.x); same(stick.activation.y, out.activation.y);
            same(stick.activation.width, out.activation.width); same(stick.activation.height, out.activation.height);
        }
        TouchLayout roundTrip = TouchLayout.read(scaled.jsonBytes());
        for (TouchLayout.Button b : scaled.buttons) {
            same(b.width, roundTrip.button(b.id).width);
            same(b.height, roundTrip.button(b.id).height);
            same(b.cornerRadius, roundTrip.button(b.id).cornerRadius);
        }
        TouchLayout saturated = original;
        for (int i = 0; i < 100; i++) saturated = saturated.withButtonScale(.9);
        for (int i = 0; i < 100; i++) saturated = saturated.withButtonScale(1.0 / .9);
        for (TouchLayout.Button b : saturated.buttons) {
            if (b.width < .04 || b.width > .4 || b.height < .04 || b.height > .4)
                throw new AssertionError("saturation escaped legal bounds");
            checks++;
        }
        original.withButtonScale(Double.MIN_VALUE);
        TouchLayout roundoff = original;
        for (TouchLayout.Button b : original.buttons)
            roundoff = roundoff.withButton(b.id, b.x, b.y, .14566843023791312,
                .14566843023791312, .05);
        same(.04, roundoff.withButtonScale(.01).button("A").width);
        for (TouchLayout.Button b : original.buttons)
            roundoff = roundoff.withButton(b.id, b.x, b.y, .35367664391787657,
                .35367664391787657, .05);
        same(.4, roundoff.withButtonScale(10).button("A").width);
        TouchLayout wide = original.withButton("A", .2, .3, .4, .04, .02);
        // One button at both legal bounds prevents global scaling in either direction.
        same(.4, wide.withButtonScale(2).button("A").width);
        same(.04, wide.withButtonScale(.5).button("A").height);
        same(.11, original.button("A").width); // original model remains immutable
        for (double factor : new double[] {0, -1, Double.NaN, Double.POSITIVE_INFINITY}) {
            boolean rejected = false;
            try { original.withButtonScale(factor); }
            catch (IllegalArgumentException expected) { rejected = true; }
            checks++;
            if (!rejected) throw new AssertionError("invalid factor accepted: " + factor);
        }
        padEdits();
        System.out.println("PASS: " + checks + " model assertions");
    }
}
