package;

import haxe.io.Bytes;
import haxe.io.BytesInput;

class BinReader {
    var bi : BytesInput;

    public function new(b : Bytes) {
        bi = new BytesInput(b);
        bi.bigEndian = false;
    }

    public function readI32() : Int    { return bi.readInt32(); }
    public function readU32() : Int    { return bi.readInt32(); }  // same bits, Int type
    public function readBool() : Bool  { return bi.readByte() != 0; }
    public function readBytes(n : Int) : Bytes { return bi.read(n); }

    public function readUtf8(n : Int) : String {
        var b = bi.read(n);
        return b.getString(0, n);
    }

    public function skip(n : Int) : Void { bi.position += n; }
    public function pos() : Int          { return bi.position; }
    public function remaining() : Int    { return bi.length - bi.position; }
    public function eof() : Bool         { return bi.position >= bi.length; }

    /** Reinterpret Int bits as hex string (unsigned display) */
    public static function hexU32(v : Int) : String {
        return StringTools.hex(v, 8).toLowerCase();
    }

    /** Parse 8-char hex string back to Int (same bits).
        Uses two 16-bit halves to avoid strtol overflow on Windows
        (where long is 32-bit even on 64-bit, causing values > 0x7FFFFFFF
        to be clamped to LONG_MAX = 2147483647). */
    public static function parseHex(s : String) : Int {
        if (s == null || s.length == 0) return 0;
        if (s.length != 8) {
            var v = Std.parseInt("0x" + s);
            return v != null ? v : 0;
        }
        var hi = Std.parseInt("0x" + s.substr(0, 4));
        var lo = Std.parseInt("0x" + s.substr(4, 4));
        if (hi == null) hi = 0;
        if (lo == null) lo = 0;
        return (hi << 16) | lo;
    }
}
