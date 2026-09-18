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

            // ── 6a. Deep-parse the inner SerializedFile ──────────────────
            //   Decomposes the Unity SerializedFile into:
            //     serialized_file_info.json  — full structural info
            //     objects/                   — one .bin per object + per-object JSON
            //     object_class_summary.json  — class-name → count
            //   This makes the bytes inside the bundle human-readable
            //   instead of an opaque blob.
            var sfParseDir = FS.join(assetDir, "serialized_file");
            SerializedFileParser.parse(innerBytes, sfParseDir);

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
     *
     * IMPLEMENTATION NOTE: We deliberately avoid `BytesOutput.getBytes()` for
     * reading back bytes we just wrote. On hxcpp, calling `getBytes()` returns
     * a view onto the underlying buffer; if a subsequent `writeByte()` causes
     * the buffer to reallocate (which it routinely does once capacity is
     * exceeded), that view becomes a dangling pointer and `.get(...)` throws
     * "Null Object Reference". This affected every INTERNALBUNDLE in
     * trouble.kitchenfire.2080314857.pcf — the LZ4-compressed light-probe
     * bundles all triggered the bug, so the UnityFS parser silently failed
     * and the inner_serialized.bin / bundle_info.json / etc. were never
     * written.
     *
     * The fix is to keep the decoded output in a self-managed growable
     * `Array<Int>` (each element 0..255). Array element access on hxcpp is
     * bounds-checked and returns 0 for out-of-range reads, never throws,
     * and the array is never reallocated in a way that invalidates prior
     * element reads. We convert to Bytes once at the end.
     */
    static function decompressLZ4(src : Bytes, expectedSize : Int) : Null<Bytes> {
        var out    = new Array<Int>();  // growable, never invalidates prior reads
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
            for (i in 0...litLen) out.push(src.get(sp + i));
            sp += litLen;

            if (sp >= srcLen) break;

            // match offset (2 bytes LE)
            if (sp + 1 >= srcLen) break;
            var matchOff = src.get(sp) | (src.get(sp + 1) << 8);
            sp += 2;
            if (matchOff == 0) return null;  // LZ4 spec: offset 0 is forbidden

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

            // copy from already-decoded output (may overlap).
            // We read directly from `out` (the Array<Int>) — never via a
            // snapshot — so overlapping copies see bytes we just wrote.
            var matchPos = out.length - matchOff;
            if (matchPos < 0) return null;
            for (j in 0...matchLen) {
                // out[matchPos + j] is always valid because either:
                //   - matchPos + j < out.length  (was written earlier), or
                //   - matchPos + j == out.length - 1 + something (just written
                //     in this loop iteration), which we then read on the next
                //     iteration. Array indexing is safe either way.
                out.push(out[matchPos + j]);
            }
        }
        // Convert to Bytes once at the end — no risk of dangling pointers.
        var result = Bytes.alloc(out.length);
        for (i in 0...out.length) result.set(i, out[i] & 0xFF);
        return result;
    }

    /**
     * LZMA decompression.
     *
     * Unity's LZMA format: 5-byte properties (1 byte lc/lp/pb + 4 bytes dictSize LE)
     * followed by the raw LZMA1 bitstream. No uncompressed-size header, no .xz
     * container. We try multiple system tools in order:
     *
     *   1. `lzma -d`  (xz-utils on Linux/macOS, command name `lzma`)
     *   2. `xz --format=lzma -d` (xz-utils, alternate command name)
     *   3. `python3 -c "import lzma, sys; ..."` (Python 3.3+ stdlib, all OSes)
     *   4. `python -c "..."` (older Python, in case `python3` isn't on PATH)
     *   5. `7z e -so -an -ailzm` (7-Zip, common on Windows)
     *
     * This covers virtually every environment the tool might be run in.
     * For `lzma` and `xz`, we wrap the data into the LZMA-alone format
     * (5-byte props + 8-byte uncompressed size = 0xFFFFFFFFFFFFFFFF + raw stream)
     * because those tools expect a complete .lzma file rather than a raw stream.
     * For `python` and `7z`, we pass the raw bytes (props + LZMA1 stream) and
     * let them decode it directly via format=FORMAT_ALONE / -ailzm.
     */
    static function decompressLZMA(data : Bytes, expectedSize : Int) : Null<Bytes> {
        var tmpdir = Sys.getEnv("TMPDIR");
        if (tmpdir == null) tmpdir = Sys.getEnv("TEMP");
        if (tmpdir == null) tmpdir = Sys.getEnv("TMP");
        if (tmpdir == null) tmpdir = "/tmp";
        var tmpIn = FS.join(tmpdir, "pcf_lzma_in.bin");
        var tmpInAlone = FS.join(tmpdir, "pcf_lzma_alone.bin");

        // Build two input files:
        //   - tmpIn:       raw LZMA1 with 5-byte props header (for Python/7z)
        //   - tmpInAlone:  LZMA-alone format = props(5) + uncompressedSize(-1, 8 bytes) + stream (for lzma/xz)
        File.saveBytes(tmpIn, data);
        var w = new BytesOutput();
        w.writeBytes(data, 0, 5);                         // 5-byte LZMA props
        // uncompressed size = -1 (unknown) in LE — required by .lzma alone format
        w.writeByte(0xFF); w.writeByte(0xFF); w.writeByte(0xFF); w.writeByte(0xFF);
        w.writeByte(0xFF); w.writeByte(0xFF); w.writeByte(0xFF); w.writeByte(0xFF);
        w.writeBytes(data, 5, data.length - 5);          // raw LZMA1 stream
        File.saveBytes(tmpInAlone, w.getBytes());

        var tried : Array<String> = [];

        // 1. lzma (xz-utils, Linux/macOS)
        if (tryCmd("lzma")) {
            tried.push("lzma");
            var out = runCmd("lzma", ["-d", "--single-stream", "-c", tmpInAlone]);
            if (out != null) {
                cleanTmp(tmpIn); cleanTmp(tmpInAlone);
                return out;
            }
        }

        // 2. xz (xz-utils, alternate name)
        if (tryCmd("xz")) {
            tried.push("xz");
            var out = runCmd("xz", ["--decompress", "--single-stream", "--format=lzma", "-c", tmpInAlone]);
            if (out != null) {
                cleanTmp(tmpIn); cleanTmp(tmpInAlone);
                return out;
            }
        }

        // 3. python3 with lzma module (Python 3.3+ stdlib — works on all OSes)
        // Uses FORMAT_ALONE which expects the standard .lzma file format
        // (5-byte props + 8-byte uncompressed size + raw stream). We pass tmpInAlone
        // which is exactly that.
        if (tryCmd("python3")) {
            tried.push("python3");
            var pyScript =
                "import lzma, sys; " +
                "data = open(sys.argv[1], 'rb').read(); " +
                "dec = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE); " +
                "sys.stdout.buffer.write(dec.decompress(data))";
            var out = runCmd("python3", ["-c", pyScript, tmpInAlone]);
            if (out != null && out.length > 0) {
                cleanTmp(tmpIn); cleanTmp(tmpInAlone);
                return out;
            }
        }

        // 4. python (older name, same script)
        if (tryCmd("python")) {
            tried.push("python");
            var pyScript =
                "import lzma, sys; " +
                "data = open(sys.argv[1], 'rb').read(); " +
                "dec = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE); " +
                "sys.stdout.buffer.write(dec.decompress(data))";
            var out = runCmd("python", ["-c", pyScript, tmpInAlone]);
            if (out != null && out.length > 0) {
                cleanTmp(tmpIn); cleanTmp(tmpInAlone);
                return out;
            }
        }

        // 5. 7z (7-Zip, common on Windows; supports LZMA via -ailzm input format)
        if (tryCmd("7z")) {
            tried.push("7z");
            var out = runCmd("7z", ["e", "-so", "-an", "-ailzm", tmpInAlone]);
            if (out != null) {
                cleanTmp(tmpIn); cleanTmp(tmpInAlone);
                return out;
            }
        }

        // All attempts failed — tell user what to install
        Sys.println('  [UnityBundleParser] LZMA decompression failed — no LZMA tool found on PATH.');
        Sys.println('  [UnityBundleParser] Tried: ' + (tried.length > 0 ? tried.join(", ") : "(none found)") );
        Sys.println('  [UnityBundleParser] Install ONE of:');
        Sys.println('  [UnityBundleParser]   - Python 3.3+ (https://www.python.org/)  ← recommended, cross-platform');
        Sys.println('  [UnityBundleParser]   - xz-utils (provides `lzma` and `xz` commands)');
        Sys.println('  [UnityBundleParser]   - 7-Zip (https://www.7-zip.org/, provides `7z` command)');
        cleanTmp(tmpIn); cleanTmp(tmpInAlone);
        return null;
    }

    /** Run a command, return its stdout bytes (or null on failure). */
    static function runCmd(cmd : String, args : Array<String>) : Null<Bytes> {
        try {
            var proc = new Process(cmd, args);
            // Read stdout first — this typically blocks until the process
            // closes its stdout (i.e., finishes writing).
            var stdout = proc.stdout.readAll();
            // Now stderr should be readable without blocking.
            var stderr = "";
            try { stderr = proc.stderr.readAll().toString(); } catch (_) {}
            var exitCode = proc.exitCode();
            proc.close();
            if (exitCode != 0) {
                var errTrim = StringTools.trim(stderr);
                if (errTrim.length > 200) errTrim = errTrim.substring(0, 200);
                Sys.println('  [UnityBundleParser] $cmd failed (exit $exitCode): $errTrim');
                return null;
            }
            if (stdout.length == 0) {
                Sys.println('  [UnityBundleParser] $cmd produced no output');
                return null;
            }
            return stdout;
        } catch (e : Dynamic) {
            Sys.println('  [UnityBundleParser] $cmd raised: $e');
            return null;
        }
    }

    static function cleanTmp(path : String) : Void {
        try { FileSystem.deleteFile(path); } catch (_) {}
    }

    /** Quick `which`-style check — runs the command with `--version` or `-version`
        to see if it's on PATH. Returns true if the command exists (regardless of exit code). */
    static function tryCmd(cmd : String) : Bool {
        // Try several flag variants since different tools accept different flags.
        for (arg in [["--version"], ["-version"], ["-V"], ["/?"]]) {
            try {
                var p = new Process(cmd, arg);
                var code = p.exitCode();
                p.close();
                return true;  // existed; even non-zero exit means the binary is on PATH
            } catch (_) {
                // continue to next arg
            }
        }
        return false;
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /**
     * Re-pack a Unity SerializedFile into a UnityFS AssetBundle.
     *
     * Mirrors UnityPy's BundleFile.save_fs():
     *   1. Chunk-compress the SerializedFile bytes with LZ4HC (256KB chunks)
     *      via system `lz4` binary or Python `lz4.block.compress(high_compression)`.
     *   2. Build blocksInfo (16-byte hash + blockCount + block entries +
     *      fileCount + file entries — file is the SerializedFile we're packing).
     *   3. Compress blocksInfo with LZ4HC (same compression as data).
     *   4. Write UnityFS header + compressed blocksInfo + compressed data.
     *
     * Used by Packer.hx when re-serializing an INTERNALBUNDLE whose
     * per-object JSON has been edited.
     *
     * Returns: the new UnityFS bundle bytes (can be written to bundle_data.bin).
     */
    public static function packBundle(serializedFileBytes : Bytes,
                                        bundleMeta : Dynamic,
                                        originalBundle : Bytes) : Bytes {
        // Try to use LZ4HC compression via system binary or Python.
        // If compression fails, fall back to no compression (flags = 0x40 = blocksAndDirCombined, compType=0)
        var compFlag = 3;  // LZ4HC by default (matches original Plotagon bundles)
        var compressedData : Bytes = null;
        var blockInfo : Array<{u : Int, c : Int, f : Int}> = [];

        // Try chunked LZ4HC compression (256KB chunks, matching Unity)
        var chunkSize = 0x40000;  // 256KB
        var pos = 0;
        var compressedBuf = new haxe.io.BytesBuffer();
        var allOK = true;
        while (pos < serializedFileBytes.length) {
            var chunkLen = Std.int(Math.min(chunkSize, serializedFileBytes.length - pos));
            var chunk = serializedFileBytes.sub(pos, chunkLen);
            var compChunk = compressLZ4HC(chunk);
            if (compChunk == null) {
                // Compression failed — fall back to no compression
                compFlag = 0;
                compressedBuf = new haxe.io.BytesBuffer();  // reset
                allOK = false;
                break;
            }
            if (compChunk.length >= chunkLen) {
                // Compression didn't help — store uncompressed (flag indicates this)
                compressedBuf.addBytes(chunk, 0, chunk.length);
                blockInfo.push({u: chunkLen, c: chunkLen, f: compFlag ^ 0x3F});
            } else {
                compressedBuf.addBytes(compChunk, 0, compChunk.length);
                blockInfo.push({u: chunkLen, c: compChunk.length, f: compFlag});
            }
            pos += chunkLen;
        }
        if (allOK) {
            compressedData = compressedBuf.getBytes();
        } else {
            // No compression — use raw data as one block
            compressedData = serializedFileBytes;
            blockInfo = [{u: serializedFileBytes.length, c: serializedFileBytes.length, f: compFlag}];
        }

        // Build blocksInfo
        // 1. 16-byte uncompressed data hash (zeros — Unity writes zeros)
        // 2. blockCount (i32 BE) + block entries
        // 3. fileCount (i32 BE) + file entries
        var bi = new haxe.io.BytesBuffer();
        for (_ in 0...16) bi.addByte(0);
        bi = writeBE32(bi, blockInfo.length);
        for (b in blockInfo) {
            bi = writeBE32(bi, b.u);
            bi = writeBE32(bi, b.c);
            bi = writeBE16(bi, b.f);
        }
        // File entry: offset=0, size, flags=4, name (null-terminated)
        var fileName : String = "CAB-Untitled";
        if (bundleMeta != null && Reflect.hasField(bundleMeta, "unityFS")) {
            var ufs : Dynamic = Reflect.field(bundleMeta, "unityFS");
            if (ufs != null && Reflect.hasField(ufs, "directories")) {
                var dirs : Array<Dynamic> = Reflect.field(ufs, "directories");
                if (dirs != null && dirs.length > 0 && Reflect.hasField(dirs[0], "path")) {
                    fileName = dirs[0].path;
                }
            }
        }
        bi = writeBE32(bi, 1);  // file count
        // offset (i64 BE) — we'll patch later, use placeholder
        bi = writeBE32(bi, 0); bi = writeBE32(bi, 0);
        // size (i64 BE)
        bi = writeBE32(bi, 0); bi = writeBE32(bi, serializedFileBytes.length);
        // flags (u32 BE)
        bi = writeBE32(bi, 4);
        // name (null-terminated)
        for (i in 0...fileName.length) bi.addByte(fileName.charCodeAt(i));
        bi.addByte(0);
        var blocksInfoUncompressed = bi.getBytes();

        // Compress blocksInfo with LZ4HC (same compFlag)
        var blocksInfoCompressed = compressLZ4HC(blocksInfoUncompressed);
        if (blocksInfoCompressed == null || blocksInfoCompressed.length >= blocksInfoUncompressed.length) {
            // Fall back to uncompressed blocksInfo (flag 0x40 means blocksAndDirCombined + compType 0)
            blocksInfoCompressed = blocksInfoUncompressed;
            // In this case, dataFlag should not include compression
            // (we'll set it to 0x40 — blocksAndDirCombined, no compression)
            // But we already set compressedData — so we need to use uncompressed everywhere
            // For simplicity, fall back to no compression entirely
            compressedData = serializedFileBytes;
            blockInfo = [{u: serializedFileBytes.length, c: serializedFileBytes.length, f: 0}];
            compFlag = 0;
        }

        // Build the data flag: 0x40 (blocksAndDirCombined) | compFlag
        var dataFlag = 0x40 | compFlag;

        // Compute file size
        var headerSize = 8 + 4 + 1 + 1 + 1 + 1 + 8 + 4 + 4 + 4;  // signature + version + version_player + version_engine + fileSize + compBI + uncompBI + flags
        // Actually UnityFS header is:
        //   signature ("UnityFS\0", 8 bytes)
        //   version (u32 BE) = 6
        //   versionPlayer (null-terminated string)
        //   versionEngine (null-terminated string)
        //   fileSize (i64 BE)
        //   compressedBlocksInfoSize (u32 BE)
        //   uncompressedBlocksInfoSize (u32 BE)
        //   flags (u32 BE)
        // We need versionPlayer + versionEngine strings from the original bundle
        var versionPlayer : String = "5.x.x";
        var versionEngine : String = "5.3.3f1";
        if (bundleMeta != null && Reflect.hasField(bundleMeta, "unityFS")) {
            var ufs : Dynamic = Reflect.field(bundleMeta, "unityFS");
            if (ufs != null) {
                if (Reflect.hasField(ufs, "unityVersion"))
                    versionPlayer = Reflect.field(ufs, "unityVersion");
                if (Reflect.hasField(ufs, "generatorVersion"))
                    versionEngine = Reflect.field(ufs, "generatorVersion");
            }
        }

        // Compute total file size: header + blocksInfo + data
        // Header size depends on strings
        var headerLen = 8 + 4 + (versionPlayer.length + 1) + (versionEngine.length + 1) + 8 + 4 + 4 + 4;
        var totalFileSize = headerLen + blocksInfoCompressed.length + compressedData.length;

        // Write the final bundle
        var out = new haxe.io.BytesBuffer();
        // Signature
        for (c in "UnityFS".split('')) out.addByte(c.charCodeAt(0));
        out.addByte(0);
        // Version (u32 BE) = 6
        out = writeBE32(out, 6);
        // versionPlayer (null-terminated)
        for (c in versionPlayer.split('')) out.addByte(c.charCodeAt(0));
        out.addByte(0);
        // versionEngine (null-terminated)
        for (c in versionEngine.split('')) out.addByte(c.charCodeAt(0));
        out.addByte(0);
        // fileSize (i64 BE)
        out = writeBE32(out, 0); out = writeBE32(out, totalFileSize);
        // compressedBlocksInfoSize (u32 BE)
        out = writeBE32(out, blocksInfoCompressed.length);
        // uncompressedBlocksInfoSize (u32 BE)
        out = writeBE32(out, blocksInfoUncompressed.length);
        // flags (u32 BE)
        out = writeBE32(out, dataFlag);
        // Compressed blocksInfo
        out.addBytes(blocksInfoCompressed, 0, blocksInfoCompressed.length);
        // Compressed data
        out.addBytes(compressedData, 0, compressedData.length);
        return out.getBytes();
    }

    /** Compress bytes with LZ4HC via Python's lz4.block.compress(high_compression). */
    static function compressLZ4HC(data : Bytes) : Null<Bytes> {
        // Save to temp file
        var tmpdir = Sys.getEnv("TMPDIR");
        if (tmpdir == null) tmpdir = Sys.getEnv("TEMP");
        if (tmpdir == null) tmpdir = Sys.getEnv("TMP");
        if (tmpdir == null) tmpdir = "/tmp";
        var tmpIn = tmpdir + "/pcf_lz4hc_in.bin";
        File.saveBytes(tmpIn, data);

        // Try Python with lz4 library
        var candidates = ["python3", "python"];
        for (pyCmd in candidates) {
            if (!tryCmd(pyCmd)) continue;
            // First check if lz4 is available
            var probe = runCmd(pyCmd, ["-c", "import lz4.block; print('ok')"]);
            if (probe == null || StringTools.trim(probe.toString()) != "ok") continue;
            // Compress with LZ4HC (high_compression mode)
            var script =
                "import lz4.block, sys; " +
                "data = open(sys.argv[1], 'rb').read(); " +
                "comp = lz4.block.compress(data, mode='high_compression', compression=9, store_size=False); " +
                "sys.stdout.buffer.write(comp)";
            var out = runCmd(pyCmd, ["-c", script, tmpIn]);
            cleanTmp(tmpIn);
            return out;
        }
        // Try system lz4 binary
        if (tryCmd("lz4")) {
            // lz4 -9 -B5 -f input.bin stdout  (LZ4HC mode = -9, block size 5 = 64KB? Actually -B5 = 256KB)
            // Actually for high compression: lz4 -9 -f input.bin output
            // For block format (no header): use --no-frame-decompression ?
            // lz4 binary may not support --no-frame, fall back to Python
            // For now, return null and let caller fall back to uncompressed
            cleanTmp(tmpIn);
            return null;
        }
        cleanTmp(tmpIn);
        return null;
    }

    /** Write a big-endian u32 to a BytesBuffer. */
    static function writeBE32(buf : haxe.io.BytesBuffer, v : Int) : haxe.io.BytesBuffer {
        buf.addByte((v >> 24) & 0xFF);
        buf.addByte((v >> 16) & 0xFF);
        buf.addByte((v >> 8) & 0xFF);
        buf.addByte(v & 0xFF);
        return buf;
    }

    /** Write a big-endian u16 to a BytesBuffer. */
    static function writeBE16(buf : haxe.io.BytesBuffer, v : Int) : haxe.io.BytesBuffer {
        buf.addByte((v >> 8) & 0xFF);
        buf.addByte(v & 0xFF);
        return buf;
    }

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
