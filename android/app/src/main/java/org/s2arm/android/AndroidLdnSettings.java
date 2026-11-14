// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.system.ErrnoException;
import android.system.Os;
import android.util.Log;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.TextView;
import android.widget.Toast;

/** Production preferences; the library passes a snapshot across the :game boundary. */
final class AndroidLdnSettings {
    private static final String PREFS = "ldn";
    private static final String MODE = "org.s2arm.android.LDN_MODE";
    private static final String ADDRESS = "org.s2arm.android.LDN_ADDRESS";
    private static boolean applied;

    private static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static LdnSettings load(Context context) {
        SharedPreferences prefs = preferences(context);
        return new LdnSettings(prefs.getString("mode", "auto"), prefs.getString("address", ""));
    }

    static void copyToLaunch(Context context, Intent intent) {
        LdnSettings settings = load(context);
        intent.putExtra(MODE, settings.mode);
        intent.putExtra(ADDRESS, settings.address);
    }

    /** Once per process, before createGame/create can initialize Host's static LDN policy. */
    static synchronized void apply(Context context, Intent intent) {
        if (applied) return;
        LdnSettings settings = intent != null && intent.hasExtra(MODE)
            ? new LdnSettings(intent.getStringExtra(MODE), intent.getStringExtra(ADDRESS)) : load(context);
        settings.apply(new LdnSettings.Environment() {
            public String get(String key) { return Os.getenv(key); }
            public void set(String key, String value) {
                try { Os.setenv(key, value, true); }
                catch (ErrnoException error) { throw new IllegalStateException("Cannot set " + key, error); }
            }
        });
        applied = true;
        if ("client".equals(settings.mode) && settings.address.isEmpty())
            Log.w("S2Arm", "Manual LDN client has no IPv4 address; using 0.0.0.0 (no automatic discovery)");
    }

    static void show(Activity activity) {
        LdnSettings saved = load(activity);
        LinearLayout content = new LinearLayout(activity);
        content.setOrientation(LinearLayout.VERTICAL);
        int pad = Math.round(16 * activity.getResources().getDisplayMetrics().density);
        content.setPadding(pad, pad, pad, pad);
        TextView help = new TextView(activity);
        help.setText(R.string.ldn_help);
        content.addView(help);
        RadioGroup modes = new RadioGroup(activity);
        String[] values = {"auto", "host", "client"};
        int[] labels = {R.string.ldn_auto, R.string.ldn_host, R.string.ldn_client};
        for (int i = 0; i < values.length; i++) {
            RadioButton button = new RadioButton(activity);
            button.setId(i + 1);
            button.setText(labels[i]);
            modes.addView(button);
            if (values[i].equals(saved.mode)) modes.check(i + 1);
        }
        content.addView(modes);
        EditText address = new EditText(activity);
        address.setSingleLine(true);
        address.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI);
        address.setHint(R.string.ldn_address);
        address.setText(saved.address);
        content.addView(address);
        android.widget.ScrollView scroll = new android.widget.ScrollView(activity);
        scroll.addView(content);
        new AlertDialog.Builder(activity).setTitle(R.string.ldn_settings).setView(scroll)
            .setPositiveButton(R.string.ldn_save, (dialog, which) -> {
                int selected = modes.getCheckedRadioButtonId() - 1;
                LdnSettings settings = new LdnSettings(values[selected], address.getText().toString());
                preferences(activity).edit().putString("mode", settings.mode)
                    .putString("address", settings.address).apply();
                Toast.makeText(activity, R.string.ldn_saved, Toast.LENGTH_LONG).show();
            })
            .setNegativeButton(android.R.string.cancel, null).show();
    }
}
