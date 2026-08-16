package;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import sys.io.File;
import sys.io.Process;
import sys.FileSystem;

/**
 * Targeted UnityFS (AssetBundle) parser for Plotagon INTERNALBUNDLE resources.
 *
 * These bundles contain an internal SerializedFile with light probe data
 * (LightingDataContainer).  The parser:
 *   1. Reads the UnityFS header (big-endian)
 *   2. Decompresses blocks info + data blocks (LZ4 / LZ4HC / LZMA)
 *   3. Saves the raw inner SerializedFile for tools / roundtrip
 *   4. Writes a human-readable bundle_info.json
 *
 * Zero external dependencies.  LZ4 block decompression is implemented in
 * pure Haxe; LZMA falls back to the system 'lzma' command (available on
 * Linux / macOS / Windows via xz-utils).
 *
 * File layout (blocksInfoAtEnd = false):
 *   [UnityFS header] [compressed blocks-info] [compressed data blocks]
 *
 * File layout (blocksInfoAtEnd = true):
 *   [UnityFS header] [compressed data blocks] [compressed blocks-info]
 */
class UnityBundleParser {

    // ── Public API ───────────────────────────────────────────────────────

    /**
     * Parse a raw Unity AssetBundle and write structured output to assetDir.
     * Returns true on success.
     */
    public static function parse(bundleBytes : Bytes, assetDir : String) : Bool {
        FS.mkdirs(assetDir);
        try {
            var r = new BEReader(bundleBytes);

            // ── 1. UnityFS header ──────────────────────────────────────────
            var header = readFSHeader(r);
            if (header == null) {
                Sys.println('  [UnityBundleParser] Not a valid UnityFS bundle');
                return false;
            }

            var flags     : Int  = Reflect.field(header, "flags");
            var compBI    : Int  = Reflect.field(header, "compressedBlocksInfoSize");
            var compType  : Int  = flags & 0x3F;
            var infoAtEnd : Bool = (flags & 0x80) != 0;

            var blocksInfoRaw : Null<Bytes>    = null;
            var dataBlockStart : Int            = 0;
            var blocks          : Array<BlockInfo> = [];
            var dirs            : Array<DirInfo>   = [];

            if (infoAtEnd) {
                // ── blocks info is at the END of the file ────────────────
                var biFileOff     = bundleBytes.length - compBI;
                blocksInfoRaw    = bundleBytes.sub(biFileOff, compBI);
                dataBlockStart   = r.pos(); // right after header
            } else {
                // ── blocks info follows the header ───────────────────────
                blocksInfoRaw = r.readBytes(compBI);
                // Reader is now positioned right after the compressed blocks
                // info — exactly where the data blocks begin.
                dataBlockStart = r.pos();
            }

            // Decompress blocks info
            var blocksInfo = decompress(blocksInfoRaw,
                Reflect.field(header, "uncompressedBlocksInfoSize"), compType);
            if (blocksInfo == null) {
                Sys.println('  [UnityBundleParser] Failed to decompress blocks info');
                return false;
            }

            // ── 3. Parse blocks info ───────────────────────────────────────
            var biR = new BEReader(blocksInfo);
            biR.skip(16); // storageBlockHash
            var blockCount = biR.readI32();
            for (i in 0...blockCount) {
                var uSize = biR.readI32();
                var cSize = biR.readI32();
                var flgs  = biR.readU16();
                blocks.push({ uSize: uSize, cSize: cSize, flags: flgs });
            }

            var dirCount = biR.readI32();
            for (i in 0...dirCount) {
                var off = biR.readI64();
                var sz  = biR.readI64();
                var df  = biR.readI32();
                var p   = biR.readStringToNull();
                dirs.push({ offset: off, size: sz, flags: df, path: p });
            }

            // ── 4. Decompress data blocks ─────────────────────────────────
            r.seek(dataBlockStart);
            var innerBO = new BytesOutput();
            for (i in 0...blocks.length) {
                var blk  = blocks[i];
                if (r.remaining() < blk.cSize) {
                    Sys.println('  [UnityBundleParser] Data block $i overflows bundle');
                    return false;
                }
                var raw    = r.readBytes(blk.cSize);
                var decomp = decompress(raw, blk.uSize, blk.flags & 0x3F);
                if (decomp == null) {
                    Sys.println('  [UnityBundleParser] Failed to decompress data block $i');
                    return false;
                }
                innerBO.writeBytes(decomp, 0, decomp.length);
            }
            var innerBytes = innerBO.getBytes();

            // ── 5. Parse inner SerializedFile header (shallow) ────────────
            var sfInfo = parseSerializedFileHeader(innerBytes);

            // ── 6. Write outputs ──────────────────────────────────────────
            // Raw inner SF (for tools / roundtrip)
            FS.writeBytes(FS.join(assetDir, "inner_serialized.bin"), innerBytes);

            // .unity3d alias (convenience)
            FS.writeBytes(FS.join(assetDir, "inner_serialized.unity3d"), innerBytes);

            // Structural JSON
            var info : Dynamic = {};
            Reflect.setField(info, "unityFS", header);

            var blocksArr : Array<Dynamic> = [];
            for (b in blocks) {
                var bd : Dynamic = {};
                Reflect.setField(bd, "uncompressedSize", b.uSize);
                Reflect.setField(bd, "compressedSize",   b.cSize);
                Reflect.setField(bd, "compression",      compName(b.flags & 0x3F));
                Reflect.setField(bd, "compressionType",  b.flags & 0x3F);
                blocksArr.push(bd);
            }
            Reflect.setField(info, "blocks", blocksArr);

            var dirsArr : Array<Dynamic> = [];
            for (d in dirs) {
                var dd : Dynamic = {};
                Reflect.setField(dd, "offset", d.offset);
                Reflect.setField(dd, "size",   d.size);
                Reflect.setField(dd, "flags",  d.flags);
                Reflect.setField(dd, "path",   d.path);
                dirsArr.push(dd);
            }
            Reflect.setField(info, "directories", dirsArr);

            if (sfInfo != null) {
                Reflect.setField(info, "serializedFile", sfInfo);
            }

            FS.writeJson(FS.join(assetDir, "bundle_info.json"), info);
            Sys.println('  [UnityBundleParser] Parsed: ${blocks.length} block(s), '
                + '${dirs.length} dir(s), inner SF ${innerBytes.length} bytes');
            return true;

        } catch (e : Dynamic) {
            Sys.println('  [UnityBundleParser] Error: $e');
            return false;
        }
    }

    // ── UnityFS Header ─────────────────────────────────────────────────────

    static function readFSHeader(r : BEReader) : Null<Dynamic> {
        var sig = r.readStringToNull();
        if (sig != "UnityFS") {
            return null;
        }
        var version       = r.readU32();
        var versionPlayer = r.readStringToNull();
        var versionEngine = r.readStringToNull();
        var fileSize      = r.readI64();
        var compBISize    = r.readU32();
        var uncompBISize  = r.readU32();
        var flags         = r.readU32();

        var h : Dynamic = {};
        Reflect.setField(h, "signature",                 sig);
        Reflect.setField(h, "formatVersion",             version);
        Reflect.setField(h, "unityVersion",              versionPlayer);
        Reflect.setField(h, "generatorVersion",          versionEngine);
        Reflect.setField(h, "fileSize",                  Std.string(fileSize));
        Reflect.setField(h, "compressedBlocksInfoSize",  compBISize);
        Reflect.setField(h, "uncompressedBlocksInfoSize", uncompBISize);
        Reflect.setField(h, "flags",                     flags);
        Reflect.setField(h, "compressionType",           flags & 0x3F);
        Reflect.setField(h, "compressionName",           compName(flags & 0x3F));
        Reflect.setField(h, "blocksInfoAtEnd",           (flags & 0x80) != 0);
        Reflect.setField(h, "blocksAndDirCombined",      (flags & 0x40) != 0);
        return h;
    }

    // ── SerializedFile Header (shallow) ────────────────────────────────────

    static function parseSerializedFileHeader(data : Bytes) : Dynamic {
        if (data.length < 20) return {};
        var sf : Dynamic = {};
        var r = new BEReader(data);
        Reflect.setField(sf, "metadataSize", r.readU32());
        Reflect.setField(sf, "fileSize",     r.readU32());
        Reflect.setField(sf, "version",      r.readU32());
        Reflect.setField(sf, "dataOffset",   r.readU32());
        Reflect.setField(sf, "unityVersion", r.readStringToNull());
        return sf;
    }

    // ── Decompression ──────────────────────────────────────────────────────

    static function decompress(data : Bytes, expectedSize : Int,
                                compType : Int) : Null<Bytes> {
        switch (compType) {
            case 0:  return data;                    // none
            case 2, 3: return decompressLZ4(data, expectedSize);
            case 1:  return decompressLZMA(data, expectedSize);
            default:
                Sys.println('  [UnityBundleParser] Unknown compression $compType');
                return null;
        }
    }

    /**
     * Pure Haxe LZ4 block decompression.
     * Standard LZ4 block format: token sequence, no frame header.
     */
    static function decompressLZ4(src : Bytes, expectedSize : Int) : Null<Bytes> {
        var out    = new BytesOutput();
        var sp     = 0;
        var srcLen = src.length;
        while (sp < srcLen) {
            var token = src.get(sp++);
            if (sp >= srcLen) break;

            // literal length
            var litLen = (token >> 4) & 0x0F;
            if (litLen == 15) {
                while (sp < srcLen) {
                    var b = src.get(sp++);
                    litLen += b;
                    if (b != 255) break;
                }
            }

            // copy literals
            if (sp + litLen > srcLen) return null;
            for (i in 0...litLen) out.writeByte(src.get(sp + i));
            sp += litLen;

            if (sp >= srcLen) break;

            // match offset (2 bytes LE)
            if (sp + 1 >= srcLen) break;
            var matchOff = src.get(sp) | (src.get(sp + 1) << 8);
            sp += 2;

            // match length
            var matchLen = token & 0x0F;
            if (matchLen == 15) {
                while (sp < srcLen) {
                    var b = src.get(sp++);
                    matchLen += b;
                    if (b != 255) break;
                }
            }
            matchLen += 4; // minimum match length

            // copy from already-decoded output (may overlap)
            var matchPos = out.length - matchOff;
            if (matchPos < 0) return null;
            for (j in 0...matchLen) {
                out.writeByte(out.getBytes().get(matchPos + j));
            }
        }
        return out.getBytes();
    }

    /**
     * LZMA decompression via system 'lzma' command.
     * Unity's LZMA format: 5 bytes properties + LZMA1 raw stream.
     * We re-wrap into LZMA alone format for xz-utils.
     */
    static function decompressLZMA(data : Bytes, expectedSize : Int) : Null<Bytes> {
        var tmpdir = Sys.getEnv("TMPDIR");
        if (tmpdir == null) tmpdir = "/tmp";
        var tmpIn = FS.join(tmpdir, "pcf_lzma_in.bin");

        // Build LZMA alone format with unknown uncompressed size
        var w = new BytesOutput();
        w.writeBytes(data, 0, 5); // props(1) + dictSize(4)
        // uncompressed size = -1 (unknown) in LE
        w.writeByte(0xFF); w.writeByte(0xFF); w.writeByte(0xFF); w.writeByte(0xFF);
        w.writeByte(0xFF); w.writeByte(0xFF); w.writeByte(0xFF); w.writeByte(0xFF);
        // Raw LZMA1 stream (everything after the 5-byte header)
        w.writeBytes(data, 5, data.length - 5);
        File.saveBytes(tmpIn, w.getBytes());

        // Try 'lzma' first (xz-utils), then fall back to 'xz'
        var cmd  = "";
        var args : Array<String> = [];
        if (tryCmd("lzma")) {
            cmd  = "lzma";
            args = ["-d", "--single-stream", "-c", tmpIn];
        } else if (tryCmd("xz")) {
            cmd  = "xz";
            args = ["--decompress", "--single-stream", "--format=lzma", "-c", tmpIn];
        } else {
            Sys.println('  [UnityBundleParser] Neither lzma nor xz found on PATH');
            Sys.println('  [UnityBundleParser] Install xz-utils for LZMA support');
            cleanTmp(tmpIn);
            return null;
        }

        try {
            var proc   = new Process(cmd, args);
            var stdout = proc.stdout.readAll();
            proc.close();
            cleanTmp(tmpIn);
            if (stdout.length == 0) {
                Sys.println('  [UnityBundleParser] $cmd produced no output');
                return null;
            }
            return stdout;
        } catch (e : Dynamic) {
            Sys.println('  [UnityBundleParser] LZMA decompression failed: $e');
            cleanTmp(tmpIn);
            return null;
        }
    }

    static function cleanTmp(path : String) : Void {
        try { FileSystem.deleteFile(path); } catch (_) {}
    }

    static function tryCmd(cmd : String) : Bool {
        try {
            var p = new Process(cmd, ["--version"]);
            p.close();
            return true;
        } catch (_) {
            return false;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    static function compName(t : Int) : String {
        return switch (t) {
            case 0: "None";
            case 1: "LZMA";
            case 2: "LZ4";
            case 3: "LZ4HC";
            default: "Unknown($t)";
        };
    }
}

// ── Big-Endian Reader ─────────────────────────────────────────────────────

class BEReader {
    var bi : BytesInput;
    public function new(b : Bytes) {
        bi = new BytesInput(b);
        bi.bigEndian = true;
    }
    public function readI32() : Int  { return bi.readInt32(); }
    public function readU32() : Int  { return bi.readInt32(); } // same bits, unsigned context
    public function readU16() : Int  { return bi.readUInt16(); }
    public function readI64() : Float {
        var hi = bi.readInt32();
        var lo = bi.readInt32();
        return hi * 4294967296.0 + (lo < 0 ? lo + 4294967296.0 : lo);
    }
    public function readByte() : Int    { return bi.readByte(); }
    public function readBytes(n : Int) : Bytes {
        return bi.read(n);
    }
    public function readStringToNull() : String {
        var buf = new StringBuf();
        while (true) {
            var b = bi.readByte();
            if (b == 0) break;
            buf.addChar(b);
        }
        return buf.toString();
    }
    public function skip(n : Int) : Void { bi.position += n; }
    public function seek(p : Int) : Void { bi.position = p; }
    public function pos() : Int     { return bi.position; }
    public function remaining() : Int { return bi.length - bi.position; }
}

// ── Types ─────────────────────────────────────────────────────────────────

typedef BlockInfo = {
    uSize : Int,
    cSize : Int,
    flags : Int
}

typedef DirInfo = {
    offset : Float,
    size   : Float,
    flags  : Int,
    path   : String
}
