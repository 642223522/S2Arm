#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Real dialog/policy, offline Android boundary. Socket connector alone is replaced.
No APK, layout rendering, real networking or libc environment behavior is proved.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
JAVA = ROOT / 'app/src/main/java/org/s2arm/android'
STUBS = {
'android/content/DialogInterface.java': '''package android.content; public interface DialogInterface { interface OnClickListener {void onClick(DialogInterface d,int w);} interface OnShowListener {void onShow(DialogInterface d);} }''',
'android/content/SharedPreferences.java': '''package android.content; public class SharedPreferences { public java.util.Map<String,String> data=new java.util.HashMap<>(); public int writes; public String getString(String k,String d){return data.getOrDefault(k,d);} public SharedPreferences edit(){return this;} public SharedPreferences putString(String k,String v){data.put(k,v);return this;} public void apply(){writes++;} }''',
'android/content/Context.java': '''package android.content; public class Context {public static final int MODE_PRIVATE=0; public SharedPreferences prefs=new SharedPreferences(); public SharedPreferences getSharedPreferences(String n,int m){return prefs;} public String getString(int id,Object... a){return "resource:"+id+java.util.Arrays.toString(a);} public android.content.res.Resources getResources(){return new android.content.res.Resources();}}''',
'android/content/res/Resources.java': '''package android.content.res; public class Resources {public static class Metrics {public float density=1;} public Metrics getDisplayMetrics(){return new Metrics();}}''',
'android/content/Intent.java': '''package android.content; public class Intent {java.util.Map<String,String> m=new java.util.HashMap<>(); public void putExtra(String k,String v){m.put(k,v);} public boolean hasExtra(String k){return m.containsKey(k);} public String getStringExtra(String k){return m.get(k);}}''',
'android/app/Activity.java': '''package android.app; public class Activity extends android.content.Context {public volatile Runnable pending; public boolean destroyed,finishing; public void runOnUiThread(Runnable r){pending=r;} public boolean isDestroyed(){return destroyed;} public boolean isFinishing(){return finishing;}}''',
'android/view/View.java': '''package android.view; public class View {public interface OnClickListener {void onClick(View v);} public OnClickListener click; public boolean enabled=true; public void setOnClickListener(OnClickListener l){click=l;} public void setEnabled(boolean e){enabled=e;} public void click(){if(click!=null)click.onClick(this);} public void setId(int i){} public void requestFocus(){} }''',
'android/widget/TextView.java': '''package android.widget; public class TextView extends android.view.View {public static java.util.List<TextView> all=new java.util.ArrayList<>(); public String text=""; public TextView(android.content.Context c){all.add(this);} public void setText(int i){text="resource:"+i;} public void setText(CharSequence s){text=s.toString();} public CharSequence getText(){return text;} }''',
'android/widget/EditText.java': '''package android.widget; public class EditText extends TextView {public static EditText last; public CharSequence error; public EditText(android.content.Context c){super(c);last=this;} public void setSingleLine(boolean b){} public void setInputType(int t){} public void setHint(int t){} public void setError(CharSequence s){error=s;} public void addTextChangedListener(android.text.TextWatcher w){} }''',
'android/widget/Button.java': '''package android.widget; public class Button extends TextView {public Button(android.content.Context c){super(c);}}''',
'android/widget/RadioButton.java': '''package android.widget; public class RadioButton extends Button {public RadioButton(android.content.Context c){super(c);}}''',
'android/widget/LinearLayout.java': '''package android.widget; public class LinearLayout extends android.view.View {public static final int VERTICAL=1; public LinearLayout(android.content.Context c){} public void setOrientation(int o){} public void setPadding(int a,int b,int c,int d){} public void addView(android.view.View v){} }''',
'android/widget/ScrollView.java': '''package android.widget; public class ScrollView extends LinearLayout {public ScrollView(android.content.Context c){super(c);}}''',
'android/widget/RadioGroup.java': '''package android.widget; public class RadioGroup extends LinearLayout {public interface OnCheckedChangeListener {void onCheckedChanged(RadioGroup g,int id);} public static RadioGroup last; int id=-1; public RadioGroup(android.content.Context c){super(c);last=this;} public void check(int n){id=n;} public int getCheckedRadioButtonId(){return id;} public void setOnCheckedChangeListener(OnCheckedChangeListener l){} }''',
'android/widget/Toast.java': '''package android.widget; public class Toast {public static final int LENGTH_LONG=1; public static Toast makeText(android.content.Context c,int s,int t){return new Toast();} public void show(){} }''',
'android/app/AlertDialog.java': '''package android.app; public class AlertDialog implements android.content.DialogInterface {public static final int BUTTON_POSITIVE=-1,BUTTON_NEUTRAL=-3; public static AlertDialog last; boolean showing; android.content.DialogInterface.OnShowListener listener; android.widget.Button save,test; public AlertDialog(Activity a){save=new android.widget.Button(a);test=new android.widget.Button(a);last=this;} public void setOnShowListener(android.content.DialogInterface.OnShowListener l){listener=l;} public android.widget.Button getButton(int i){return i==BUTTON_POSITIVE?save:test;} public boolean isShowing(){return showing;} public void show(){showing=true;listener.onShow(this);} public void dismiss(){showing=false;} public static class Builder {AlertDialog d; public Builder(Activity a){d=new AlertDialog(a);} public Builder setTitle(int i){return this;} public Builder setView(android.view.View v){return this;} public Builder setPositiveButton(int i,android.content.DialogInterface.OnClickListener l){return this;} public Builder setNeutralButton(int i,android.content.DialogInterface.OnClickListener l){return this;} public Builder setNegativeButton(int i,android.content.DialogInterface.OnClickListener l){return this;} public AlertDialog create(){return d;}} }''',
'android/system/ErrnoException.java': '''package android.system; public class ErrnoException extends Exception {}''',
'android/system/Os.java': '''package android.system; public class Os {public static java.util.Map<String,String> env=new java.util.HashMap<>(); public static String getenv(String k){return env.get(k);} public static void setenv(String k,String v,boolean b)throws ErrnoException{env.put(k,v);}}''',
'android/util/Log.java': '''package android.util; public class Log {public static int w(String a,String b){return 0;} public static int i(String a,String b,Throwable t){return 0;} }''',
'android/text/InputType.java': '''package android.text; public class InputType {public static final int TYPE_CLASS_TEXT=1,TYPE_TEXT_VARIATION_URI=2;}''',
'android/text/Editable.java': '''package android.text; public interface Editable extends CharSequence {}''',
'android/text/TextWatcher.java': '''package android.text; public interface TextWatcher {void beforeTextChanged(CharSequence s,int a,int b,int c);void onTextChanged(CharSequence s,int a,int b,int c);void afterTextChanged(Editable e);}''',
'android/R.java': '''package android; public class R {public static class string {public static int cancel=1;}}''',
}
PROBE = r'''package org.s2arm.android;
import android.app.*; import android.widget.*;
public class DialogProbe {
 static int checks;
 static void ck(boolean ok,String why){checks++;if(!ok)throw new AssertionError(why);}
 static Activity open(String mode,String address){Activity a=new Activity();a.prefs.data.put("mode",mode);a.prefs.data.put("address",address);AndroidLdnSettings.show(a);return a;}
 static void save(){AlertDialog.last.getButton(-1).click();}
 static void pending(Activity a)throws Exception {long end=System.nanoTime()+3000000000L;while(a.pending==null&&System.nanoTime()<end)Thread.yield();ck(a.pending!=null,"offline callback delivered");}
 public static void main(String[] args)throws Exception {
  for(String ip:new String[]{"", "999.1.2.3", "1.2.3", "1.2.3.4:30456"}){
   Activity a=open("client",ip);save();ck(a.prefs.writes==0,"invalid client must not save");ck(AlertDialog.last.isShowing(),"invalid dialog remains open");ck(EditText.last.error!=null&&EditText.last.error.toString().startsWith("resource:"+(ip.isEmpty()?R.string.ldn_address_empty:R.string.ldn_address_invalid)),"named address error");
  }
  Activity a=open("client"," 100.64.1.8 ");save();ck(a.prefs.writes==1&&"100.64.1.8".equals(a.prefs.data.get("address")),"trimmed IPv4 saves");ck(!AlertDialog.last.isShowing(),"valid save dismisses");
  for(String mode:new String[]{"host","auto"}){a=open(mode,"bad old address");save();ck(a.prefs.writes==1,"host/auto ignore stale invalid address");}
  a=open("client","1.2.3.4");RadioGroup.last.check(-1);save();ck(a.prefs.writes==0&&AlertDialog.last.isShowing(),"no selected mode must not save or crash");
  a=open("client","1.2.3.4");AlertDialog.last.getButton(-3).click();pending(a);a.pending.run();ck(AlertDialog.last.getButton(-3).enabled,"failed connection re-enables test");save();ck(a.prefs.writes==1,"connection failure does not gate save");
  for(boolean destroy:new boolean[]{false,true}){a=open("client","1.2.3.4");AlertDialog d=AlertDialog.last;d.getButton(-3).click();pending(a);TextView result=TextView.all.get(TextView.all.size()-3);String before=result.text;if(destroy)a.destroyed=true;else d.dismiss();a.pending.run();ck(!d.getButton(-3).enabled&&before.equals(result.text),"late callback must not mutate UI after close/destroy");}
  a=open("client","100.64.1.9");android.content.Intent i=new android.content.Intent();AndroidLdnSettings.copyToLaunch(a,i);a.prefs.data.put("address","1.2.3.4");AndroidLdnSettings.apply(a,i);ck("100.64.1.9".equals(android.system.Os.env.get("S2A_LDN_SERVER")),"intent snapshot wins");android.system.Os.env.put("S2A_LDN_SERVER","sentinel");AndroidLdnSettings.apply(a,i);ck("sentinel".equals(android.system.Os.env.get("S2A_LDN_SERVER")),"apply once");
  System.out.println("dialog checks="+checks);
 }
}'''


class DialogTest(unittest.TestCase):
    def run_probe(self, mutant=False):
        source = (JAVA / 'AndroidLdnSettings.java').read_text(encoding='utf-8')
        connector = '''try (java.net.Socket socket = new java.net.Socket()) {
                                socket.connect(new java.net.InetSocketAddress(target, port), timeout);
                            }'''
        self.assertEqual(source.count(connector), 1, 'production connector changed; review offline replacement')
        source = source.replace(connector, 'throw new java.io.IOException("offline injected failure");')
        if mutant:
            point = 'LdnSettings.AddressError error = settings.addressError();'
            self.assertEqual(source.count(point), 1)
            source = source.replace(point, 'LdnSettings.AddressError error = null;')
        import re
        ids = sorted(set(re.findall(r'R\.string\.(\w+)', source)))
        stubs = dict(STUBS)
        stubs['org/s2arm/android/R.java'] = 'package org.s2arm.android; public class R {public static class string {' + ''.join('public static final int %s=%d;' % (key, n+10) for n, key in enumerate(ids)) + '}}'
        stubs['org/s2arm/android/AndroidLdnSettings.java'] = source
        stubs['org/s2arm/android/LdnSettings.java'] = (JAVA / 'LdnSettings.java').read_text(encoding='utf-8')
        stubs['org/s2arm/android/DialogProbe.java'] = PROBE
        with tempfile.TemporaryDirectory(prefix='ldn-dialog-') as tmp:
            files = []
            for relative, text in stubs.items():
                path = Path(tmp) / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding='utf-8')
                files.append(str(path))
            subprocess.run(['javac', '-encoding', 'UTF-8', '-d', tmp, *files], check=True)
            return subprocess.run(['java', '-ea', '-cp', tmp, 'org.s2arm.android.DialogProbe'], capture_output=True, text=True)

    def test_dialog(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())

    def test_ignoring_address_error_is_red(self):
        result = self.run_probe(mutant=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid client must not save', result.stderr)


if __name__ == '__main__':
    unittest.main()
