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

    /** Parse 8-char hex string back to Int (same bits) */
    public static function parseHex(s : String) : Int {
        return Std.parseInt("0x" + s);
    }
}
