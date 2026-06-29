package;

import haxe.io.Bytes;
import haxe.io.BytesOutput;

class BinWriter {
    var bo : BytesOutput;

    public function new() {
        bo = new BytesOutput();
        bo.bigEndian = false;
    }

    public function writeI32(v : Int)  : Void { bo.writeInt32(v); }
    public function writeBool(v : Bool): Void { bo.writeByte(v ? 1 : 0); }

    public function writeBytes(b : Bytes) : Void {
        bo.writeBytes(b, 0, b.length);
    }

    public function writeUtf8(s : String) : Void {
        var b = Bytes.ofString(s);
        bo.writeBytes(b, 0, b.length);
    }

    public function len() : Int    { return bo.length; }
    public function get() : Bytes  { return bo.getBytes(); }
}
