#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#528 item 15: the library's "last session ended abnormally" notice, on the real LibraryActivity.

Compiles the production LibraryActivity / GameLibrary with the Android stand-ins of game_library_import_test.py
(recording Button / View / TextView, a settable running-game pid, a recording LastSessionNotice and
DiagnosticExport) and drives onCreate / onResume over the session marker the :game process keeps
(LastSession, files/s2a_session.mark). Expectations are written by hand from the maintainer's terms on #528:
fg and no game process -> one non-blocking notice, marker cleared; bg / none / game still running -> nothing;
the notice's buttons reuse the More panel's export path. Three negative controls mutate a copy of the source.
Real crashes, ApplicationExitInfo and the on-screen layout need a device (left to the maintainers' test phone).
"""
from pathlib import Path
import importlib.util
import subprocess
import tempfile
import textwrap
import unittest

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('game_library_import_test', HERE / 'game_library_import_test.py')
_imports = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_imports)
JAVA = _imports.JAVA
LIBRARY_ACTIVITY = JAVA / 'org/s2arm/android/LibraryActivity.java'


def _replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'stand-in changed, cannot patch: {old[:60]}')
    return text.replace(old, new)


def stubs():
    out = {k: v for k, v in _imports.STUBS.items() if not k.endswith('ImportProbe.java')}
    out['android/view/View.java'] = _replace(out['android/view/View.java'],
        'public void setEnabled(boolean enabled){throw new AssertionError("diagnostic export unexpectedly called");}',
        'public static final java.util.List<Object[]> enabledLog=new java.util.concurrent.CopyOnWriteArrayList<>();'
        ' public void setEnabled(boolean enabled){enabledLog.add(new Object[]{this,enabled});}')
    out['android/widget/TextView.java'] = _replace(out['android/widget/TextView.java'],
        'public void setText(String s){messages.add(s);} public void setText(int i){}',
        'public volatile String text; public int textId;'
        ' public void setText(String s){text=s;messages.add(s);} public void setText(int i){textId=i;}')
    out['android/widget/Button.java'] = '''package android.widget; import android.content.Context; import android.view.View;
 public class Button extends TextView { public static final java.util.List<Button> all=new java.util.ArrayList<>(); private View.OnClickListener listener;
 public Button(Context c){super(c);all.add(this);} public void setOnClickListener(View.OnClickListener l){listener=l;}
 public void performClick(){listener.onClick(this);} }'''
    out['android/app/AlertDialog.java'] = _replace(out['android/app/AlertDialog.java'],
        'public AlertDialog show(){return new AlertDialog();}',
        'public AlertDialog show(){shown++;return new AlertDialog();} public static int shown;')
    out['org/s2arm/android/GameActivity.java'] = _replace(out['org/s2arm/android/GameActivity.java'],
        'public static int runningPid(Context c){return 0;}', 'public static int pid; public static int runningPid(Context c){return pid;}')
    out['org/s2arm/android/LastSessionNotice.java'] = '''package org.s2arm.android; import android.content.Context;
 public class LastSessionNotice { static volatile int calls; static volatile long markedAt;
 static String text(Context context,long t){calls++;markedAt=t;return "NOTICE";} }'''
    out['org/s2arm/android/DiagnosticExport.java'] = '''package org.s2arm.android; import android.content.Context; import java.io.IOException; import java.nio.file.Path;
 public class DiagnosticExport { static volatile int calls;
 public static Path run(Context context) throws IOException {calls++;throw new IOException("fixture: no export here");} }'''
    # The export path's own status lines (export_diagnostics_* 3-6, save_diagnostics_* 116-118) may be asked here.
    out['android/content/Context.java'] = _replace(out['android/content/Context.java'],
        'if(id>=7&&id<=15||', 'if(id>=3&&id<=6||id>=116&&id<=119||id>=7&&id<=15||')
    out['org/s2arm/android/LastSessionProbe.java'] = PROBE
    return out


PROBE = r'''package org.s2arm.android;
import java.io.*; import java.lang.reflect.*; import java.nio.file.*;
public class LastSessionProbe {
 static int checks;
 static void demand(boolean ok,String what){checks++;if(!ok)throw new AssertionError(what);}
 static Object field(Object o,String n) throws Exception {Field f=LibraryActivity.class.getDeclaredField(n);f.setAccessible(true);return f.get(o);}
 static boolean shown(LibraryActivity a) throws Exception {return ((android.view.View)field(a,"notice")).getVisibility()==android.view.View.VISIBLE;}
 static boolean eventually(java.util.concurrent.Callable<Boolean> test) throws Exception {
  long end=System.nanoTime()+5_000_000_000L; while(System.nanoTime()<end){if(test.call())return true;Thread.sleep(20);} return test.call(); }
 static Path marker(Path root){return root.resolve("internal").resolve(LastSession.FILE);}
 static void mark(Path root,String text) throws IOException {Files.createDirectories(marker(root).getParent());Files.write(marker(root),text.getBytes("US-ASCII"));}
 static LibraryActivity open(Path root){android.app.Activity.testRoot=root.toFile();android.widget.Button.all.clear();LibraryActivity a=new LibraryActivity();a.onCreate(null);return a;}
 static android.widget.Button button(int textId,int nth){int seen=0;for(android.widget.Button b:android.widget.Button.all)if(b.textId==textId&&seen++==nth)return b;throw new AssertionError("no button "+textId+"#"+nth);}
 static void quiet(LibraryActivity a,String why) throws Exception {Thread.sleep(200);demand(!shown(a)&&LastSessionNotice.calls==0,why);}
 public static void main(String[] args) throws Exception {
  Path base=Paths.get(args[0]);
  // No marker: the last session ended normally.
  Path none=base.resolve("none");LibraryActivity a=open(none);
  try {a.onResume();quiet(a,"no marker must not show a notice");} finally {a.onDestroy();}
  // bg: closed or reclaimed in the background, not abnormal; the marker stays for the next game session to overwrite.
  Path bg=base.resolve("bg");mark(bg,"bg\n");a=open(bg);
  try {a.onResume();quiet(a,"bg marker must not show a notice");demand(Files.exists(marker(bg)),"bg marker must be kept");} finally {a.onDestroy();}
  // fg while a game process is alive (split screen keeps the game in front next to the library): not asked, marker kept.
  Path live=base.resolve("live");mark(live,"fg\n");android.widget.Button.all.clear();GameActivity.pid=4242;a=open(live);
  try {a.onResume();quiet(a,"a running game must not be reported as ended");demand(Files.exists(marker(live)),"running game's marker must be kept");}
  finally {a.onDestroy();GameActivity.pid=0;}
  // fg and no game process: one notice, its text from LastSessionNotice with the marker's time, marker cleared.
  Path fg=base.resolve("fg");mark(fg,"fg\n");long when=marker(fg).toFile().lastModified();a=open(fg);
  try {
   a.onResume();
   final LibraryActivity shownActivity=a;
   demand(eventually(() -> shown(shownActivity)),"fg marker without a game process must show the notice");
   demand(LastSessionNotice.calls==1&&LastSessionNotice.markedAt==when,"notice text must be asked once with the marker's time");
   demand("NOTICE".equals(((android.widget.TextView)field(a,"noticeText")).text),"notice must show LastSessionNotice's text");
   demand(!Files.exists(marker(fg)),"the marker must be cleared once the notice is shown");
   a.onResume();Thread.sleep(200);
   demand(LastSessionNotice.calls==1,"a later resume must not ask again");
   button(R.string.last_session_dismiss,0).performClick();
   demand(!shown(a),"dismiss must hide the notice");
  } finally {a.onDestroy();}
  // The notice's export reuses the More panel's export path and button.
  Path again=base.resolve("export");mark(again,"fg\n");LastSessionNotice.calls=0;a=open(again);
  try {
   a.onResume();final LibraryActivity exporting=a;
   demand(eventually(() -> shown(exporting)),"second fg marker must show the notice");
   android.widget.Button panelExport=button(R.string.export_diagnostics,0),noticeExport=button(R.string.export_diagnostics,1);
   android.view.View.enabledLog.clear();noticeExport.performClick();
   demand(!shown(a),"choosing export must hide the notice");
   demand(eventually(() -> DiagnosticExport.calls==1),"notice export must run the existing DiagnosticExport");
   boolean panelBusy=false,noticeBusy=false;
   for(Object[] e:android.view.View.enabledLog){if(e[0]==panelExport&&Boolean.FALSE.equals(e[1]))panelBusy=true;if(e[0]==noticeExport)noticeBusy=true;}
   demand(panelBusy&&!noticeBusy,"the More panel's export button must carry the busy state, not a second path");
  } finally {a.onDestroy();}
  demand(android.app.AlertDialog.Builder.shown==0,"the notice must never block the library with a dialog");
  System.out.println("PASS last-session notice on actual LibraryActivity: "+checks+" checks");
 }
}
'''

CHECK_CALL = '        checkLastSession();\n'
RUNNING_GUARD = ' || GameActivity.runningPid(this) != 0'
CLEAR = 'try { LastSession.mark(dir, LastSession.NONE); }'


class LastSessionNoticeTest(unittest.TestCase):
    def run_probe(self, mutate=None):
        with tempfile.TemporaryDirectory(prefix='s2a-last-session-') as temporary:
            base = Path(temporary)
            sources = []
            for relative, content in stubs().items():
                path = base / 'src' / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(textwrap.dedent(content), encoding='utf-8')
                sources.append(str(path))
            activity = LIBRARY_ACTIVITY
            if mutate:
                old, new = mutate
                text = LIBRARY_ACTIVITY.read_text(encoding='utf-8')
                self.assertEqual(text.count(old), 1, old)
                activity = base / 'LibraryActivity.java'
                activity.write_text(text.replace(old, new), encoding='utf-8')
            compiled = subprocess.run(['javac', '-encoding', 'UTF-8', '-d', str(base / 'classes'), '-sourcepath', str(JAVA),
                                       str(activity), *sources], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            return subprocess.run(['java', '-Djava.io.tmpdir=' + str(base), '-cp', str(base / 'classes'),
                                   'org.s2arm.android.LastSessionProbe', str(base / 'data')],
                                  capture_output=True, text=True, timeout=60)

    def test_notice_contract(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS last-session notice on actual LibraryActivity: 16 checks', result.stdout)

    def test_no_check_on_resume_negative_control(self):
        result = self.run_probe((CHECK_CALL, ''))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fg marker without a game process must show the notice', result.stderr)

    def test_running_game_guard_negative_control(self):
        result = self.run_probe((RUNNING_GUARD, ''))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('a running game must not be reported as ended', result.stderr)

    def test_marker_not_cleared_negative_control(self):
        result = self.run_probe((CLEAR, 'try { if (dir == null) LastSession.mark(dir, LastSession.NONE); }'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('the marker must be cleared once the notice is shown', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
