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

    /** 8-char hex string → Int (same bit pattern) */
    public static function unhex8(s : String) : Int {
        return Std.parseInt("0x" + s);
    }
}
