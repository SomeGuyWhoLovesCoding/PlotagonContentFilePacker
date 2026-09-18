package;

import sys.FileSystem;
import sys.io.File;
import haxe.io.Bytes;
import haxe.io.Path;

class FS {
    // ---- Directory helpers ------------------------------------------------

    public static function mkdirs(path : String) : Void {
        if (path == "" || path == "." || FileSystem.exists(path)) return;
        mkdirs(Path.directory(path));
        FileSystem.createDirectory(path);
    }

    public static function mkdir(path : String) : Void {
        if (!FileSystem.exists(path)) FileSystem.createDirectory(path);
    }

    public static function exists(path : String) : Bool {
        return FileSystem.exists(path);
    }

    /** List immediate subdirectory names, sorted alphabetically. */
    public static function subdirs(path : String) : Array<String> {
        if (!FileSystem.exists(path)) return [];
        var result = FileSystem.readDirectory(path)
            .filter(n -> FileSystem.isDirectory(path + "/" + n));
        result.sort((a,b) -> a < b ? -1 : a > b ? 1 : 0);
        return result;
    }

    /** List immediate file names (non-dirs), sorted. */
    public static function files(path : String) : Array<String> {
        if (!FileSystem.exists(path)) return [];
        var result = FileSystem.readDirectory(path)
            .filter(n -> !FileSystem.isDirectory(path + "/" + n));
        result.sort((a,b) -> a < b ? -1 : a > b ? 1 : 0);
        return result;
    }

    public static function join(a : String, b : String) : String {
        if (a == "") return b;
        if (a.charAt(a.length-1) == "/") return a + b;
        return a + "/" + b;
    }

    // ---- File I/O ---------------------------------------------------------

    public static function readBytes(path : String) : Bytes {
        return File.getBytes(path);
    }

    public static function writeBytes(path : String, b : Bytes) : Void {
        File.saveBytes(path, b);
    }

    public static function readJson(path : String) : Dynamic {
        return haxe.Json.parse(File.getContent(path));
    }

    public static function writeJson(path : String, v : Dynamic) : Void {
        File.saveContent(path, haxe.Json.stringify(v, null, "  "));
    }

    // ---- ID helpers -------------------------------------------------------

    /** Int bits → 8-char lowercase hex, handles negative (signed) values */
    public static function hex8(v : Int) : String {
        // StringTools.hex crashes on negative ints on Neko — split into two 16-bit halves
        var hi = (v >>> 16) & 0xFFFF;
        var lo = v & 0xFFFF;
        return StringTools.hex(hi, 4).toLowerCase() + StringTools.hex(lo, 4).toLowerCase();
    }

    /** 8-char hex string → Int (same bit pattern).
        Parses as two 16-bit halves to avoid strtol overflow on platforms
        where `long` is 32-bit (e.g., 64-bit Windows LLP64 model). On those
        platforms, Std.parseInt("0x894bfbb9") calls strtol which overflows
        and returns LONG_MAX (2147483647) for ANY value > 0x7FFFFFFF,
        clamping all high-bit-set resourceIDs to the same value → duplicate
        key errors in Plotagon's C# ResourceBlock.SetBytes dictionary. */
    public static function unhex8(s : String) : Int {
        if (s == null || s.length == 0) return 0;
        if (s.length != 8) {
            var v = Std.parseInt("0x" + s);
            return v != null ? v : 0;
        }
        // Parse as two independent 16-bit halves — each fits in Int without
        // overflow on any platform. Then combine with (hi << 16) | lo.
        var hi = Std.parseInt("0x" + s.substr(0, 4));
        var lo = Std.parseInt("0x" + s.substr(4, 4));
        if (hi == null) hi = 0;
        if (lo == null) lo = 0;
        return (hi << 16) | lo;
    }
}
