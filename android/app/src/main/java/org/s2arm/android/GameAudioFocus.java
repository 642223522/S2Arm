package org.s2arm.android;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import java.util.function.Consumer;

/** Android audio focus for a foreground game; callbacks run on the UI thread. */
final class GameAudioFocus {
    private final AudioFocusPolicy policy;
    GameAudioFocus(Context context, Consumer<Boolean> output) {
        AudioManager manager = context.getSystemService(AudioManager.class);
        policy = new AudioFocusPolicy(new AudioFocusPolicy.Backend() {
            private AudioFocusRequest request;
            @Override public boolean request(Consumer<Boolean> change) {
                if (manager == null) { Log.e("S2Arm", "Audio focus service unavailable"); return false; }
                AudioAttributes attrs = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_GAME)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
                request = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs).setWillPauseWhenDucked(false)
                    .setOnAudioFocusChangeListener(focus -> AudioFocusPolicy.focusChange(change,
                            focus == AudioManager.AUDIOFOCUS_GAIN,
                            focus == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK),
                        new Handler(Looper.getMainLooper())).build();
                try {
                    if (manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return true;
                    Log.e("S2Arm", "Audio focus request denied");
                } catch (RuntimeException e) { Log.e("S2Arm", "Audio focus request failed", e); }
                request = null;
                return false;
            }
            @Override public void abandon() {
                if (manager != null && request != null) {
                    try { manager.abandonAudioFocusRequest(request); }
                    catch (RuntimeException e) { Log.e("S2Arm", "Audio focus release failed", e); }
                    request = null;
                }
            }
        }, output);
    }
    void resume() { policy.resume(); }
    void pause() { policy.pause(); }
}
