// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
public final class SaveTransferTest {
    static native byte[] transfer(byte[] request, int mode);
    static native int calls();
    static native int frees();
    static int checks;
    static void check(boolean ok) { if (!ok) throw new AssertionError("check " + checks); checks++; }
    static void rejects(Class<? extends Throwable> type, byte[] bytes, int mode) {
        try { transfer(bytes, mode); throw new AssertionError("expected " + type); }
        catch (RuntimeException | OutOfMemoryError ex) { check(type.isInstance(ex)); }
    }
    public static void main(String[] args) {
        System.load(args[0]);
        byte[] text = "{\"name\":\"中文😀\"}".getBytes(StandardCharsets.UTF_8);
        check(Arrays.equals(text, transfer(text, 0))); check(calls()==1 && frees()==1);
        check(transfer(new byte[0],0).length==0);
        rejects(IllegalArgumentException.class, null,0);
        rejects(IllegalArgumentException.class,new byte[]{65,0,66},0);
        rejects(IllegalArgumentException.class,new byte[(8<<20)+1],0);
        rejects(UnsupportedOperationException.class,text,1);
        rejects(UnsupportedOperationException.class,text,2);
        check(calls()==2 && frees()==2); // rejected requests never reach service
        rejects(OutOfMemoryError.class,text,3);
        rejects(IllegalStateException.class,text,4); check(frees()==3);
        byte[] limit=new byte[8<<20]; Arrays.fill(limit,(byte)'a');
        check(Arrays.equals(limit,transfer(limit,0))); check(frees()==4);
        // UTF-8 validation belongs to the managed service; transport never rewrites bytes.
        byte[] invalid={(byte)255}; check(Arrays.equals(invalid,transfer(invalid,0)));
        System.out.println("PASS " + checks + " JNI transport assertions; synthetic service only");
    }
}
