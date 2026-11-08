package org.s2arm.android;

import java.util.function.Consumer;

public final class AudioFocusPolicyTest {
    static final class Backend implements AudioFocusPolicy.Backend {
        boolean granted = true;
        int requests, abandons;
        Consumer<Boolean> callback;
        public boolean request(Consumer<Boolean> change) { requests++; callback=change; return granted; }
        public void abandon() { abandons++; }
    }
    public static void main(String[] args) {
        Backend b=new Backend(); boolean[] audible={true};
        AudioFocusPolicy p=new AudioFocusPolicy(b, x -> audible[0]=x);
        assert !audible[0];
        p.resume(); assert audible[0] && b.requests==1;
        AudioFocusPolicy.focusChange(b.callback,false,true); assert audible[0];
        b.callback.accept(false); assert !audible[0];
        AudioFocusPolicy.focusChange(b.callback,false,true); assert !audible[0];
        b.callback.accept(true); assert audible[0];
        Consumer<Boolean> old=b.callback;
        p.pause(); assert !audible[0] && b.abandons==1;
        old.accept(true); assert !audible[0];
        b.granted=false; p.resume(); assert !audible[0] && b.requests==2;
        b.callback.accept(true); assert !audible[0];
        p.pause(); b.granted=true; p.resume(); assert audible[0] && b.requests==3;
        old.accept(false); assert audible[0];
        p.pause(); assert !audible[0];
        System.out.println("audio focus lifecycle, denial and stale callbacks passed");
    }
}
