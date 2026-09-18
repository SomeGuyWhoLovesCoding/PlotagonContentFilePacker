package;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import sys.io.File;

/**
 * Pure-Haxe Unity SerializedFile parser + TypeTree reader.
 *
 * This is a faithful port of the relevant parts of UnityPy's serialization
 * code (https://github.com/K0lb3/UnityPy) to Haxe, so the tool has ZERO
 * external dependencies — no Python, no UnityPy, no system binaries.
 *
 * The parser handles:
 *   1. SerializedFile header (always big-endian)
 *   2. Endianness switch based on the header's endianness flag
 *   3. Metadata: unityVersion, targetPlatform, enableTypeTree, typeCount
 *   4. Types table: for each SerializedType, reads classID, IsStrippedType
 *      (v>=16), ScriptTypeIndex (v>=17), ScriptID/OldTypeHash (v<16 with
 *      classID<0 OR v>=16 with classID==114), TypeTree (if enabled)
 *   5. TypeTree binary blob: numNodes + stringbuffer_size + N×TypeTreeNode
 *      + string blob. Each node is 24 bytes (v<19) or 32 bytes (v>=19, with
 *      refTypeHash). String offsets resolved via per-file string buffer +
 *      the CommonStrings table for shared offsets (high bit set).
 *   6. ObjectInfo table (with version-specific pathID size, isStripped, etc.)
 *   7. ScriptTypes, Externals, RefTypes (v>=20), userInformation
 *   8. Object data extraction: for each object, slice its raw bytes from
 *      the data section starting at dataOffset + object.dataOffset
 *   9. TypeTree-driven value decoding: for each object, walk its type tree
 *      and decode primitives, strings, vectors, classes, PPtrs into a
 *      structured JSON-friendly object.
 *
 * Output written to `outDir/`:
 *   serialized_file_info.json   — full structural info (header, types, objects)
 *   object_class_summary.json   — class-name → count summary
 *   objects/                    — one .bin + one .json per object
 *   type_tree_dump.txt          — human-readable dump of each type's tree
 *
 * The output is comparable to what UnityPy would produce, but runs in pure
 * Haxe with no Python or external libraries required.
 */
class SerializedFileParser {

    // ── Unity ClassID → ClassName ──────────────────────────────────────────
    static var CLASS_NAMES : Map<Int, String> = [
        1   => "GameObject",          4   => "Transform",
        21  => "Material",            26  => "Light",
        28  => "Texture2D",           33  => "MeshFilter",
        43  => "Mesh",                48  => "Shader",
        49  => "TextAsset",           65  => "BoxCollider",
        74  => "AnimationClip",       83  => "AudioClip",
        114 => "MonoBehaviour",       115 => "MonoScript",
        142 => "AssetBundle",         150 => "PreloadData",
        180 => "LightProbeGroup",     194 => "LightProbes",
        213 => "LightingDataAsset",   258 => "LightingDataContainer",
    ];

    public static function className(classID : Int) : String {
        return CLASS_NAMES.exists(classID) ? CLASS_NAMES.get(classID) : 'Class_$classID';
    }

    // ── Public entry point ────────────────────────────────────────────────

    public static function parse(data : Bytes, outDir : String) : Bool {
        if (data.length < 20) {
            Sys.println('  [SerializedFileParser] File too small (${data.length}b)');
            return false;
        }
        try {
            var r = new SFReader(data, true);  // start in BE for header

            // ── 1. Header (always BIG-ENDIAN) ─────────────────────────────
            var metadataSize = r.readU32();
            var fileSize     = r.readU32();
            var version      = r.readU32();
            var dataOffset   = r.readU32();
            var endianByte   = r.readByte();
            r.skip(3);  // reserved[3]
            // v22+ has extra header fields; not used by Plotagon bundles
            if (version >= 22) {
                metadataSize = r.readU32();
                var fsHi = r.readI32(); var fsLo = r.readI32();
                var doHi = r.readI32(); var doLo = r.readI32();
                // unknown (int64)
                var unkHi = r.readI32(); var unkLo = r.readI32();
            }

            // ── 2. Switch endianness based on header flag ─────────────────
            var bigEndian = endianByte != 0;
            r.setEndian(bigEndian);

            // ── 3. Metadata: unityVersion + targetPlatform + enableTypeTree
            var unityVersion = (version >= 7) ? r.readStringToNull() : "";
            var targetPlatform = (version >= 8) ? r.readI32() : 0;
            var enableTypeTree = (version >= 13) ? r.readBool() : true;

            // ── 4. Types table ─────────────────────────────────────────────
            var typeCount = r.readI32();
            var types : Array<SerializedType> = [];
            for (i in 0...typeCount) {
                types.push(readSerializedType(r, version, enableTypeTree, false));
            }

            // ── 5. big_id_enabled (7 <= version < 14) ──────────────────────
            var bigIDEnabled = 0;
            if (7 <= version && version < 14) {
                bigIDEnabled = r.readI32();
            }

            // ── 6. Objects table ──────────────────────────────────────────
            var objectCount = r.readI32();
            var objects : Array<ObjectInfo> = [];
            for (i in 0...objectCount) {
                objects.push(readObjectInfo(r, version, bigIDEnabled, types));
            }

            // ── 7. Script types (v>=11) ───────────────────────────────────
            var scriptTypes : Array<Dynamic> = [];
            if (version >= 11) {
                var scriptCount = r.readI32();
                for (i in 0...scriptCount) {
                    var st : Dynamic = {};
                    Reflect.setField(st, "index",              i);
                    Reflect.setField(st, "localFileIndex",    r.readI32());
                    if (version < 14) {
                        Reflect.setField(st, "localIdentifierInFile", r.readI32());
                    } else {
                        r.alignStream();
                        Reflect.setField(st, "localIdentifierInFile", r.readI64Str());
                    }
                    scriptTypes.push(st);
                }
            }

            // ── 8. Externals ──────────────────────────────────────────────
            var externalCount = r.readI32();
            var externals : Array<Dynamic> = [];
            for (i in 0...externalCount) {
                var ex : Dynamic = {};
                Reflect.setField(ex, "index", i);
                if (version >= 6) {
                    Reflect.setField(ex, "tempEmpty", r.readStringToNull());
                }
                if (version >= 5) {
                    Reflect.setField(ex, "guid", r.readBytes(16).toHex());
                    Reflect.setField(ex, "type",  r.readI32());
                }
                Reflect.setField(ex, "path", r.readStringToNull());
                externals.push(ex);
            }

            // ── 9. Ref types (v>=20) ──────────────────────────────────────
            var refTypes : Array<SerializedType> = [];
            if (version >= 20) {
                var refTypeCount = r.readI32();
                for (i in 0...refTypeCount) {
                    refTypes.push(readSerializedType(r, version, enableTypeTree, true));
                }
            }

            // ── 10. userInformation (v>=5) ────────────────────────────────
            var userInformation = "";
            if (version >= 5) {
                try { userInformation = r.readStringToNull(); } catch (_) {}
            }

            // ── 11. Extract each object's raw bytes + decode its TypeTree ─
            FS.mkdirs(outDir);
            var objectsDir = FS.join(outDir, "objects");
            FS.mkdirs(objectsDir);

            var objectsJson : Array<Dynamic> = [];
            for (i in 0...objects.length) {
                var o = objects[i];
                var cn = className(o.classID);
                var fnBin = 'obj_${StringTools.lpad(Std.string(i), "0", 3)}_${cn}.bin';
                var fnJson = 'obj_${StringTools.lpad(Std.string(i), "0", 3)}_${cn}.json';
                var absStart = dataOffset + o.byteStart;
                var objBytes : Null<Bytes> = null;
                if (absStart + o.byteSize <= data.length) {
                    objBytes = data.sub(absStart, o.byteSize);
                    FS.writeBytes(FS.join(objectsDir, fnBin), objBytes);
                }
                var oJson : Dynamic = {};
                Reflect.setField(oJson, "index",       i);
                Reflect.setField(oJson, "pathID",      o.pathIDStr);
                Reflect.setField(oJson, "typeID",      o.typeID);
                Reflect.setField(oJson, "classID",     o.classID);
                Reflect.setField(oJson, "className",   cn);
                Reflect.setField(oJson, "byteStart",   o.byteStart);
                Reflect.setField(oJson, "absoluteOffset", absStart);
                Reflect.setField(oJson, "byteSize",    o.byteSize);
                Reflect.setField(oJson, "isStripped",  o.isStripped);
                Reflect.setField(oJson, "scriptTypeIndex", o.scriptTypeIndex);
                if (objBytes != null) {
                    Reflect.setField(oJson, "extracted", true);
                    Reflect.setField(oJson, "rawBytes",  objBytes.length);
                    Reflect.setField(oJson, "hexPreviewFirst32", objBytes.sub(0, Std.int(Math.min(32, objBytes.length))).toHex());
                } else {
                    Reflect.setField(oJson, "extracted", false);
                }

                // Decode the object's TypeTree into structured values
                if (o.serializedType != null && o.serializedType.typeTree != null && objBytes != null) {
                    try {
                        var decoded = decodeTypeTree(o.serializedType.typeTree, objBytes, bigEndian);
                        Reflect.setField(oJson, "decoded", decoded);
                    } catch (e : Dynamic) {
                        Reflect.setField(oJson, "decodeError", Std.string(e));
                    }
                } else if (objBytes != null) {
                    // No type tree — for built-in types where the type tree
                    // is stored externally (Plotagon's bundles have type trees
                    // embedded, so this should be rare)
                    Reflect.setField(oJson, "decodeError", "no TypeTree available");
                }
                FS.writeJson(FS.join(objectsDir, fnJson), oJson);
                objectsJson.push(oJson);
            }

            // ── 12. Write top-level info + summary ────────────────────────
            var header : Dynamic = {};
            Reflect.setField(header, "metadataSize",   metadataSize);
            Reflect.setField(header, "fileSize",       fileSize);
            Reflect.setField(header, "version",        version);
            Reflect.setField(header, "dataOffset",     dataOffset);
            Reflect.setField(header, "endianness",     endianByte);
            Reflect.setField(header, "endiannessName", endianByte == 0 ? "LittleEndian" : "BigEndian");

            var typesJson : Array<Dynamic> = [];
            // Also create a types/ subfolder to hold per-type raw TypeTree bytes
            // + parsed TypeTree nodes — needed by save() to preserve metadata
            // byte-for-byte AND to re-encode object data when JSON is edited.
            var typesDir = FS.join(outDir, "types");
            FS.mkdirs(typesDir);
            for (i in 0...types.length) {
                var t = types[i];
                var tj : Dynamic = {};
                Reflect.setField(tj, "index",        i);
                Reflect.setField(tj, "classID",      t.classID);
                Reflect.setField(tj, "className",     className(t.classID));
                Reflect.setField(tj, "isStrippedType", t.isStrippedType);
                Reflect.setField(tj, "scriptTypeIndex", t.scriptTypeIndex);
                if (t.scriptID != null)     Reflect.setField(tj, "scriptID",     t.scriptID.toHex());
                if (t.oldTypeHash != null) Reflect.setField(tj, "oldTypeHash",  t.oldTypeHash.toHex());
                if (t.typeTree != null) {
                    Reflect.setField(tj, "typeTreeNodeCount", t.typeTree.allNodes.length);
                    // Save raw TypeTree bytes (so save() can preserve metadata
                    // byte-for-byte — no need to re-encode the binary blob)
                    if (t.typeTree.rawBytes != null) {
                        Reflect.setField(tj, "typeTreeBytesFile", 'types/${i}_typetree.bin');
                        FS.writeBytes(FS.join(outDir, 'types/${i}_typetree.bin'), t.typeTree.rawBytes);
                    }
                    // Save parsed TypeTree nodes as JSON (so save() can re-encode
                    // object data when JSON is edited — walk the tree to write values)
                    var nodesJson = typeTreeNodesToJson(t.typeTree.root);
                    Reflect.setField(tj, "typeTreeNodesFile", 'types/${i}_typetree.json');
                    FS.writeJson(FS.join(outDir, 'types/${i}_typetree.json'),
                        { nodes: nodesJson });
                }
                typesJson.push(tj);
            }

            var info : Dynamic = {};
            Reflect.setField(info, "header",          header);
            Reflect.setField(info, "unityVersion",    unityVersion);
            Reflect.setField(info, "targetPlatform",  targetPlatform);
            Reflect.setField(info, "platformName",    platformName(targetPlatform));
            Reflect.setField(info, "enableTypeTree",  enableTypeTree);
            Reflect.setField(info, "typeCount",       typeCount);
            Reflect.setField(info, "types",           typesJson);
            Reflect.setField(info, "objectCount",     objectCount);
            Reflect.setField(info, "objects",         objectsJson);
            Reflect.setField(info, "scriptTypeCount", scriptTypes.length);
            Reflect.setField(info, "scriptTypes",    scriptTypes);
            Reflect.setField(info, "externalCount",   externalCount);
            Reflect.setField(info, "externals",       externals);
            Reflect.setField(info, "refTypeCount",    refTypes.length);
            Reflect.setField(info, "userInformation", userInformation);
            FS.writeJson(FS.join(outDir, "serialized_file_info.json"), info);

            // Class summary
            var byClass : Map<String, Int> = new Map();
            for (o in objects) {
                var cn = className(o.classID);
                byClass.set(cn, (byClass.exists(cn) ? byClass.get(cn) : 0) + 1);
            }
            var classSummary : Array<Dynamic> = [];
            for (cn => count in byClass) {
                classSummary.push({ className: cn, count: count });
            }
            FS.writeJson(FS.join(outDir, "object_class_summary.json"),
                { classes: classSummary });
            // NOTE: To trigger re-serialization when editing per-object JSON,
            // delete `bundle_data.bin` before packing. The Packer will detect
            // its absence and re-serialize from the per-object .json files.

            // Type tree dump (textual, human-readable)
            var tt = new StringBuf();
            for (i in 0...types.length) {
                var t = types[i];
                tt.add('═══ type[$i] classID=${t.classID} (${className(t.classID)}) ═══\n');
                if (t.typeTree != null) {
                    dumpTypeTree(t.typeTree.root, tt, "  ");
                } else {
                    tt.add('  (no type tree)\n');
                }
                tt.add('\n');
            }
            File.saveContent(FS.join(outDir, "type_tree_dump.txt"), tt.toString());

            Sys.println('  [SerializedFileParser] Parsed: '
                + '${typeCount} type(s), ${objectCount} object(s), '
                + '${externalCount} external(s) (Unity ${unityVersion})');
            return true;
        } catch (e : Dynamic) {
            Sys.println('  [SerializedFileParser] Error: $e');
            return false;
        }
    }

    // ── SerializedType reader ─────────────────────────────────────────────

    static function readSerializedType(r : SFReader, version : Int,
                                        enableTypeTree : Bool, isRefType : Bool) : SerializedType {
        var t = new SerializedType();
        t.classID = r.readI32();

        if (version >= 16) {
            t.isStrippedType = r.readBool();
        }
        if (version >= 17) {
            t.scriptTypeIndex = r.readI16();
        }

        // ScriptID + OldTypeHash conditions (per UnityPy):
        //   (is_ref_type AND script_type_index >= 0) OR
        //   (version < 16 AND class_id < 0) OR
        //   (version >= 16 AND class_id == 114)
        if (version >= 13) {
            var needScriptID = (isRefType && t.scriptTypeIndex >= 0)
                             || (version < 16 && t.classID < 0)
                             || (version >= 16 && t.classID == 114);
            if (needScriptID) {
                t.scriptID = r.readBytes(16);
            }
            t.oldTypeHash = r.readBytes(16);
        }

        if (enableTypeTree) {
            // Binary blob format for version >= 12 or == 10
            if (version >= 12 || version == 10) {
                t.typeTree = parseTypeTreeBlob(r, version);
            } else {
                t.typeTree = parseTypeTreeString(r, version);
            }

            // Ref-type strings / type dependencies (v>=21)
            if (version >= 21) {
                if (isRefType) {
                    t.m_ClassName    = r.readStringToNull();
                    t.m_NameSpace    = r.readStringToNull();
                    t.m_AssemblyName = r.readStringToNull();
                } else {
                    var depCount = r.readI32();
                    var deps : Array<Int> = [];
                    for (_ in 0...depCount) deps.push(r.readI32());
                    t.typeDependencies = deps;
                }
            }
        }
        return t;
    }

    // ── TypeTree binary blob parser ─────────────────────────────────────────

    static function parseTypeTreeBlob(r : SFReader, version : Int) : TypeTree {
        var nodeCount = r.readI32();
        var stringbufferSize = r.readI32();

        // Capture the raw bytes of this TypeTree binary blob so save() can
        // preserve it byte-for-byte when re-assembling the SerializedFile.
        var blobStart = r.position();
        var nodeSize = (version >= 19) ? 32 : 24;
        var nodesBytes = r.readBytes(nodeCount * nodeSize);
        var stringBuffer = r.readBytes(stringbufferSize);
        var blobEnd = r.position();
        var rawBytes = r.getBytesRange(blobStart, blobEnd);

        var nodes : Array<TypeTreeNode> = [];
        var p = 0;
        for (_ in 0...nodeCount) {
            var node = new TypeTreeNode();
            // Common fields (24 bytes for v<19, 32 bytes for v>=19)
            // Layout: version(i16) level(u8) typeFlags(u8) typeStrOff(u32)
            //         nameStrOff(u32) byteSize(i32) index(i32) metaFlag(i32)
            //         [+ refTypeHash(u64) if v>=19]
            node.m_Version    = readI16BE(nodesBytes, p);     p += 2;
            node.m_Level     = nodesBytes.get(p);             p += 1;
            node.m_TypeFlags  = nodesBytes.get(p);             p += 1;
            node.m_TypeStrOff = readU32LE(nodesBytes, p, r);   p += 4;
            node.m_NameStrOff = readU32LE(nodesBytes, p, r);   p += 4;
            node.m_ByteSize   = readI32LE(nodesBytes, p, r);  p += 4;
            node.m_Index      = readI32LE(nodesBytes, p, r);  p += 4;
            node.m_MetaFlag   = readI32LE(nodesBytes, p, r);  p += 4;
            if (version >= 19) {
                // refTypeHash (u64) — 8 bytes
                p += 8;
            }
            // Resolve type/name strings
            node.m_Type = resolveString(node.m_TypeStrOff, stringBuffer);
            node.m_Name = resolveString(node.m_NameStrOff, stringBuffer);
            nodes.push(node);
        }

        // Build tree from flat node list using m_Level (parent/child)
        var root : Null<TypeTreeNode> = null;
        var stack : Array<TypeTreeNode> = [];
        var prev : Null<TypeTreeNode> = null;
        for (node in nodes) {
            if (prev == null) {
                root = node;
            } else if (node.m_Level > prev.m_Level) {
                stack.push(prev);
                prev.m_Children.push(node);
            } else if (node.m_Level < prev.m_Level) {
                while (stack.length > 0 && node.m_Level <= stack[stack.length - 1].m_Level) {
                    stack.pop();
                }
                if (stack.length > 0) stack[stack.length - 1].m_Children.push(node);
                else { root = node; stack = [node]; }
            } else {
                if (stack.length > 0) stack[stack.length - 1].m_Children.push(node);
                else { root = node; stack = [node]; }
            }
            prev = node;
        }

        var tt = new TypeTree();
        tt.allNodes = nodes;
        tt.root = (root != null) ? root : new TypeTreeNode();
        tt.stringBuffer = stringBuffer;
        tt.rawBytes = rawBytes;
        return tt;
    }

    /** Serialize a TypeTreeNode tree to a JSON-compatible array. */
    static function typeTreeNodesToJson(node : TypeTreeNode) : Array<Dynamic> {
        var out : Array<Dynamic> = [];
        out.push({
            m_Level:      node.m_Level,
            m_Type:       node.m_Type,
            m_Name:       node.m_Name,
            m_ByteSize:   node.m_ByteSize,
            m_Version:    node.m_Version,
            m_TypeFlags:  node.m_TypeFlags,
            m_Index:      node.m_Index,
            m_MetaFlag:   node.m_MetaFlag
        });
        for (child in node.m_Children) {
            for (n in typeTreeNodesToJson(child)) out.push(n);
        }
        return out;
    }

    /** Reconstruct a TypeTreeNode tree from a flat JSON node list (using m_Level). */
    public static function typeTreeNodesFromJson(nodesJson : Array<Dynamic>) : TypeTreeNode {
        var root = new TypeTreeNode();
        var stack : Array<TypeTreeNode> = [root];
        var prev : Null<TypeTreeNode> = null;
        for (nj in nodesJson) {
            var node = new TypeTreeNode();
            node.m_Level     = Reflect.field(nj, "m_Level");
            node.m_Type      = Reflect.field(nj, "m_Type");
            node.m_Name      = Reflect.field(nj, "m_Name");
            node.m_ByteSize  = Reflect.field(nj, "m_ByteSize");
            node.m_Version   = Reflect.field(nj, "m_Version");
            node.m_TypeFlags = Reflect.field(nj, "m_TypeFlags");
            node.m_Index     = Reflect.field(nj, "m_Index");
            node.m_MetaFlag  = Reflect.field(nj, "m_MetaFlag");
            if (prev == null) {
                root = node;
                stack = [root];
            } else if (node.m_Level > prev.m_Level) {
                stack.push(prev);
                prev.m_Children.push(node);
            } else if (node.m_Level < prev.m_Level) {
                while (stack.length > 0 && node.m_Level <= stack[stack.length - 1].m_Level) {
                    stack.pop();
                }
                if (stack.length > 0) stack[stack.length - 1].m_Children.push(node);
                else { root = node; stack = [node]; }
            } else {
                if (stack.length > 0) stack[stack.length - 1].m_Children.push(node);
                else { root = node; stack = [node]; }
            }
            prev = node;
        }
        return root;
    }

    /** Old string-based TypeTree format (v < 12, v != 10) — for completeness. */
    static function parseTypeTreeString(r : SFReader, version : Int) : TypeTree {
        // Not used by Plotagon bundles (they're v15 with blob format),
        // so we implement a minimal version that just reads the first node.
        var tt = new TypeTree();
        try {
            var root = new TypeTreeNode();
            root.m_Version = r.readI32();
            root.m_Level  = 0;
            r.readStringToNull(); // ignored
            root.m_Type   = r.readStringToNull();
            root.m_Name   = r.readStringToNull();
            root.m_ByteSize = r.readI32();
            if (version == 2) r.readI32(); // variableCount
            if (version != 3) r.readI32(); // index
            root.m_TypeFlags = r.readI32();
            root.m_Version   = r.readI32();
            if (version != 3) r.readI32(); // metaFlag
            tt.root = root;
            tt.allNodes = [root];
            tt.stringBuffer = Bytes.alloc(0);
        } catch (e : Dynamic) {}
        return tt;
    }

    // ── String resolution ───────────────────────────────────────────────────

    static function resolveString(offset : Int, stringBuffer : Bytes) : String {
        // Per UnityPy read_string():
        //   is_offset = (value & 0x80000000) == 0
        //   if is_offset: read null-terminated string at `value` in stringBuffer
        //   else: lookup in CommonStrings table by (value & 0x7FFFFFFF)
        if ((offset & 0x80000000) == 0) {
            // Offset into string buffer
            if (offset >= 0 && offset < stringBuffer.length) {
                var end = offset;
                while (end < stringBuffer.length && stringBuffer.get(end) != 0) end++;
                return stringBuffer.sub(offset, end - offset).getString(0, end - offset);
            }
            return "";
        }
        // Common string index
        var idx = offset & 0x7FFFFFFF;
        var s = CommonStrings.get(idx);
        return s != null ? s : 'common_$idx';
    }

    // ── ObjectInfo reader ──────────────────────────────────────────────────

    static function readObjectInfo(r : SFReader, version : Int, bigIDEnabled : Int,
                                    types : Array<SerializedType>) : ObjectInfo {
        var o = new ObjectInfo();
        // pathID
        if (bigIDEnabled != 0) {
            o.pathID = r.readI64Str();
        } else if (version < 14) {
            o.pathID = Std.string(r.readI32());
        } else {
            r.alignStream();
            o.pathID = r.readI64Str();
        }
        // byte_start
        if (version >= 22) {
            o.byteStart = r.readI32();  // 64-bit but unlikely > 2GB
            r.readI32(); // high 32 bits (ignored for now)
        } else {
            o.byteStart = r.readU32();
        }
        o.byteSize = r.readU32();
        o.typeID   = r.readI32();

        // classID lookup
        if (version < 16) {
            o.classID = r.readU16();
            // Find matching SerializedType by classID (matches UnityPy's loop)
            for (t in types) {
                if (t.classID == o.typeID) {
                    o.serializedType = t;
                    break;
                }
            }
        } else {
            if (o.typeID >= 0 && o.typeID < types.length) {
                o.serializedType = types[o.typeID];
                o.classID = o.serializedType.classID;
            } else {
                o.classID = -1;
            }
        }

        // is_destroyed (v<11)
        if (version < 11) {
            r.readU16();
        }
        // scriptTypeIndex (11 <= v < 17)
        if (11 <= version && version < 17) {
            o.scriptTypeIndex = r.readI16();
            if (o.serializedType != null && o.serializedType.scriptTypeIndex == -1) {
                o.serializedType.scriptTypeIndex = o.scriptTypeIndex;
            }
        }
        // is_stripped (v==15 or v==16)
        if (version == 15 || version == 16) {
            o.isStripped = r.readByte();
        }
        return o;
    }

    // ── TypeTree-driven value decoder ──────────────────────────────────────

    /**
     * Decode an object's bytes using its TypeTree, returning a
     * JSON-friendly Dynamic (dict for classes, arrays for vectors,
     * primitives where applicable).
     *
     * Faithful port of UnityPy.helpers.TypeTreeHelper.read_value().
     */
    public static function decodeTypeTree(tt : TypeTree, data : Bytes, bigEndian : Bool) : Dynamic {
        var r = new SFReader(data, bigEndian);
        return readValue(tt.root, r);
    }

    static function metaflagIsAligned(metaFlag : Null<Int>) : Bool {
        return ((metaFlag == null ? 0 : metaFlag) & 0x4000) != 0;
    }

    static function readValue(node : TypeTreeNode, r : SFReader) : Dynamic {
        var align = metaflagIsAligned(node.m_MetaFlag);

        var v : Dynamic = readPrimitive(node.m_Type, r);
        if (v != null) {
            // primitive handled
        } else if (node.m_Type == "pair") {
            var first  = readValue(node.m_Children[0], r);
            var second = readValue(node.m_Children[1], r);
            v = [first, second];
        } else if (node.m_Children.length > 0 && node.m_Children[0].m_Type == "Array") {
            if (metaflagIsAligned(node.m_Children[0].m_MetaFlag)) align = true;
            var size = r.readI32();
            if (size < 0) throw "Negative array size";
            var subtype = node.m_Children[0].m_Children[1];
            var arr : Array<Dynamic> = [];
            if (metaflagIsAligned(subtype.m_MetaFlag)) {
                for (_ in 0...size) arr.push(readValueArray(subtype, r, r.readI32()));
            } else {
                for (_ in 0...size) arr.push(readValue(subtype, r));
            }
            v = arr;
        } else {
            // Class
            var obj : Dynamic = {};
            for (child in node.m_Children) {
                Reflect.setField(obj, child.m_Name, readValue(child, r));
            }
            // PPtr<...> — flatten to a dict with m_FileID + m_PathID (already done above)
            v = obj;
        }

        if (align) r.alignStream();
        return v;
    }

    static function readValueArray(node : TypeTreeNode, r : SFReader, size : Int) : Dynamic {
        var align = metaflagIsAligned(node.m_MetaFlag);

        var v : Dynamic = readPrimitiveArray(node.m_Type, r, size);
        if (v != null) {
            // primitive array handled
        } else if (node.m_Type == "string") {
            var arr : Array<String> = [];
            for (_ in 0...size) arr.push(r.readAlignedString());
            v = arr;
        } else if (node.m_Type == "TypelessData") {
            var arr : Array<String> = [];
            for (_ in 0...size) {
                var ln = r.readI32();
                arr.push(r.readBytes(ln).toHex());
            }
            v = arr;
        } else if (node.m_Type == "pair") {
            var arr : Array<Dynamic> = [];
            for (_ in 0...size) arr.push([readValue(node.m_Children[0], r), readValue(node.m_Children[1], r)]);
            v = arr;
        } else if (node.m_Children.length > 0 && node.m_Children[0].m_Type == "Array") {
            if (metaflagIsAligned(node.m_Children[0].m_MetaFlag)) align = true;
            var subtype = node.m_Children[0].m_Children[1];
            var arr : Array<Dynamic> = [];
            if (metaflagIsAligned(subtype.m_MetaFlag)) {
                for (_ in 0...size) arr.push(readValueArray(subtype, r, r.readI32()));
            } else {
                for (_ in 0...size) {
                    var innerSize = r.readI32();
                    var inner : Array<Dynamic> = [];
                    for (_ in 0...innerSize) inner.push(readValue(subtype, r));
                    arr.push(inner);
                }
            }
            v = arr;
        } else {
            // Class
            var arr : Array<Dynamic> = [];
            for (_ in 0...size) {
                var obj : Dynamic = {};
                for (child in node.m_Children) {
                    Reflect.setField(obj, child.m_Name, readValue(child, r));
                }
                arr.push(obj);
            }
            v = arr;
        }

        if (align) r.alignStream();
        return v;
    }

    /** Read a primitive value, return null if the type isn't a primitive. */
    static function readPrimitive(type : String, r : SFReader) : Null<Dynamic> {
        return switch (type) {
            case "SInt8", "UInt8", "char":  r.readByte();
            case "short", "SInt16":         r.readI16();
            case "unsigned short", "UInt16": r.readU16();
            case "int", "SInt32":           r.readI32();
            case "unsigned int", "UInt32", "Type*": r.readU32();
            case "long long", "SInt64":     r.readI64Str();
            case "unsigned long long", "UInt64", "FileSize": r.readI64Str();
            case "float":                   r.readF32();
            case "double":                  r.readF64();
            case "bool":                    r.readBool();
            case "string":                  r.readAlignedString();
            case "TypelessData":            var len = r.readI32(); r.readBytes(len).toHex();
            default:                        null;
        };
    }

    static function readPrimitiveArray(type : String, r : SFReader, size : Int) : Null<Dynamic> {
        if (size == 0) return [];
        return switch (type) {
            case "SInt8", "UInt8", "char":  [for (_ in 0...size) r.readByte()];
            case "short", "SInt16":         [for (_ in 0...size) r.readI16()];
            case "unsigned short", "UInt16": [for (_ in 0...size) r.readU16()];
            case "int", "SInt32":           [for (_ in 0...size) r.readI32()];
            case "unsigned int", "UInt32", "Type*": [for (_ in 0...size) r.readU32()];
            case "long long", "SInt64":     [for (_ in 0...size) r.readI64Str()];
            case "unsigned long long", "UInt64", "FileSize": [for (_ in 0...size) r.readI64Str()];
            case "float":                   [for (_ in 0...size) r.readF32()];
            case "double":                  [for (_ in 0...size) r.readF64()];
            case "bool":                    [for (_ in 0...size) r.readBool()];
            default:                        null;
        };
    }

    // ── Type tree textual dump ────────────────────────────────────────────

    static function dumpTypeTree(node : TypeTreeNode, sb : StringBuf, indent : String) : Void {
        sb.add('${indent}${node.m_Type} ${node.m_Name}  // byteSize=${node.m_ByteSize} metaFlag=${node.m_MetaFlag} level=${node.m_Level}\n');
        for (child in node.m_Children) dumpTypeTree(child, sb, indent + "  ");
    }

    // ── Platform name ──────────────────────────────────────────────────────

    static function platformName(p : Int) : String {
        return switch (p) {
            case 0:  "UnknownPlatform";
            case 5:  "StandaloneWindows";
            case 9:  "StandaloneOSXIntel";
            case 13: "StandaloneLinux64";
            case 17: "iOS";
            case 25: "Android";
            default: 'Platform_$p';
        };
    }

    // ── Helpers for reading little-endian values from byte arrays ──────────

    static inline function readI16BE(b : Bytes, off : Int) : Int {
        return (b.get(off) << 8) | b.get(off + 1);
    }

    static inline function readU32LE(b : Bytes, off : Int, r : SFReader) : Int {
        // Use the SFReader's endianness setting
        if (r.isBE()) {
            return (b.get(off) << 24) | (b.get(off + 1) << 16) | (b.get(off + 2) << 8) | b.get(off + 3);
        }
        return b.get(off) | (b.get(off + 1) << 8) | (b.get(off + 2) << 16) | (b.get(off + 3) << 24);
    }

    static inline function readI32LE(b : Bytes, off : Int, r : SFReader) : Int {
        var u = readU32LE(b, off, r);
        // Convert unsigned to signed (Haxe Int is 32-bit signed).
        // Use Std.int() to coerce Float back to Int after the subtraction.
        if (u >= 2147483648) u = Std.int(u - 4294967296);
        return u;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RE-SERIALIZATION (write side — port of UnityPy's write_value + dump_blob)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Save a SerializedFile from a parsed structure + per-object decoded JSON.
     *
     * Re-assembles the SerializedFile bytes:
     *   1. Header (BE) — metadataSize, fileSize, version, dataOffset, endianness, reserved[3]
     *   2. Metadata (file endianness) — unityVersion, targetPlatform, enableTypeTree,
     *      types table (with TypeTree binary blob), objects table, script types,
     *      externals, ref types, userInformation
     *   3. Data section (16-byte aligned) — per-object re-encoded bytes (8-byte aligned)
     *
     * Returns the new SerializedFile bytes.
     */
    public static function save(info : Dynamic, objectsDir : String, bigEndian : Bool) : Bytes {
        var version : Int = Reflect.field(Reflect.field(info, "header"), "version");
        var unityVersion : String = Reflect.field(info, "unityVersion");
        var targetPlatform : Int = Reflect.field(info, "targetPlatform");
        var enableTypeTree : Bool = Reflect.field(info, "enableTypeTree");
        var types : Array<Dynamic> = Reflect.field(info, "types");
        var objects : Array<Dynamic> = Reflect.field(info, "objects");
        var scriptTypes : Array<Dynamic> = Reflect.field(info, "scriptTypes");
        var externals : Array<Dynamic> = Reflect.field(info, "externals");
        var userInformation : String = Reflect.field(info, "userInformation");
        var endiannessByte : Int = Reflect.field(Reflect.field(info, "header"), "endianness");

        // Step 1: Load each object's .bin bytes (possibly re-encoded by the Packer).
        var objBytes : Array<Bytes> = [];
        for (o in objects) {
            var cn : String = Reflect.field(o, "className");
            var idx : Int = Reflect.field(o, "index");
            var fnBin  = 'obj_${StringTools.lpad(Std.string(idx), "0", 3)}_${cn}.bin';
            var binPath  = FS.join(objectsDir, fnBin);
            if (!FS.exists(binPath)) {
                throw 'Missing object bin file: $binPath';
            }
            objBytes.push(FS.readBytes(binPath));
        }

        // Step 2: Determine the data section layout.
        // The original file places objects in the data section sorted by their
        // original byteStart (ascending). We mirror this order so the no-edit
        // round-trip is byte-identical. If any object's size changed (edits),
        // the byte_starts are recomputed sequentially.
        var dataOrder : Array<Int> = [for (i in 0...objects.length) i];
        dataOrder.sort(function(a, b) : Int {
            var ba : Int = Reflect.field(objects[a], "byteStart");
            var bb : Int = Reflect.field(objects[b], "byteStart");
            return ba - bb;
        });

        // Compute new byte_starts for each object (in data section order)
        var newByteStarts : Array<Int> = [for (_ in 0...objects.length) 0];
        var dataCursor : Int = 0;
        for (idx in dataOrder) {
            newByteStarts[idx] = dataCursor;
            dataCursor += objBytes[idx].length;
            // Align to 8 bytes (Unity convention)
            var rem = dataCursor % 8;
            if (rem != 0) dataCursor += 8 - rem;
        }

        // Step 2: Build the metadata section.
        // We need to preserve the original TypeTrees. For simplicity, we'll
        // load them from the original inner_serialized.bin if available, OR
        // re-encode from the parsed structure. The cleanest path is to also
        // save the original TypeTree bytes alongside the per-object info.
        // For now, we'll use the parsed types + their TypeTrees.
        var metaWriter = new SFWriter(bigEndian);
        if (version >= 7) metaWriter.writeStringToNull(unityVersion);
        if (version >= 8) metaWriter.writeI32(targetPlatform);
        if (version >= 13) metaWriter.writeBool(enableTypeTree);

        // Types table
        metaWriter.writeI32(types.length);
        for (t in types) {
            var classID : Int = Reflect.field(t, "classID");
            metaWriter.writeI32(classID);
            if (version >= 16) metaWriter.writeBool(Reflect.field(t, "isStrippedType"));
            if (version >= 17) metaWriter.writeI16(Reflect.field(t, "scriptTypeIndex"));
            if (version >= 13) {
                var needScriptID = (Reflect.field(t, "scriptTypeIndex") != null
                                    && Reflect.field(t, "scriptTypeIndex") >= 0)
                                 || (version < 16 && classID < 0)
                                 || (version >= 16 && classID == 114);
                if (needScriptID && Reflect.hasField(t, "scriptID")) {
                    metaWriter.writeBytes(Bytes.ofHex(Reflect.field(t, "scriptID")));
                }
                if (Reflect.hasField(t, "oldTypeHash")) {
                    metaWriter.writeBytes(Bytes.ofHex(Reflect.field(t, "oldTypeHash")));
                }
            }
            if (enableTypeTree && Reflect.hasField(t, "typeTreeBytes")) {
                // Write the original TypeTree binary blob (preserved byte-for-byte)
                metaWriter.writeBytes(Reflect.field(t, "typeTreeBytes"));
            }
            if (version >= 21) {
                var deps : Array<Int> = Reflect.field(t, "typeDependencies");
                if (deps == null) deps = [];
                metaWriter.writeI32(deps.length);
                for (d in deps) metaWriter.writeI32(d);
            }
        }

        // big_id_enabled (7 <= version < 14)
        var bigIDEnabled = 0;
        if (7 <= version && version < 14) {
            // not in our metadata — assume 0
            metaWriter.writeI32(0);
        }

        // Objects table — need to know each object's byte_start in the data section
        // We'll compute that in step 3, then come back and patch it.
        var objectByteStarts : Array<Int> = [];
        var dataCursor : Int = 0;
        for (i in 0...objBytes.length) {
            objectByteStarts.push(dataCursor);
            dataCursor += objBytes[i].length;
            // Align each object's data to 8 bytes (Unity convention)
            var rem = dataCursor % 8;
            if (rem != 0) dataCursor += 8 - rem;
        }
        // Hmm we don't know the exact dataOffset yet because metadata isn't done.
        // Two-pass: write metadata first with placeholders, then patch.
        // For simplicity, we'll compute metadata size, then write objects with
        // byte_start = dataOffset + relative_offset.
        // We'll do the two-pass here:
        var metaSizeStart = metaWriter.length;
        metaWriter.writeI32(objects.length);
        for (i in 0...objects.length) {
            var o = objects[i];
            // pathID
            if (bigIDEnabled != 0) {
                metaWriter.writeI64Str(Std.string(Reflect.field(o, "pathID")));
            } else if (version < 14) {
                metaWriter.writeI32(Std.parseInt(Std.string(Reflect.field(o, "pathID"))));
            } else {
                metaWriter.alignStream();
                metaWriter.writeI64Str(Std.string(Reflect.field(o, "pathID")));
            }
            // byte_start — placeholder, will patch later
            var bsPos = metaWriter.length;
            if (version >= 22) {
                metaWriter.writeI32(0); metaWriter.writeI32(0);  // 64-bit
            } else {
                metaWriter.writeI32(0);  // placeholder
            }
            metaWriter.writeI32(objBytes[i].length);  // byte_size
            var typeID : Int = Reflect.field(o, "typeID");
            metaWriter.writeI32(typeID);  // type_id
            if (version < 16) {
                metaWriter.writeU16(Reflect.field(o, "classID"));
            }
            if (version < 11) {
                metaWriter.writeU16(0);  // is_destroyed
            }
            if (11 <= version && version < 17) {
                var sti : Int = Reflect.field(o, "scriptTypeIndex");
                metaWriter.writeI16(sti);
            }
            if (version == 15 || version == 16) {
                metaWriter.writeByte(Reflect.field(o, "isStripped"));
            }
        }

        // Script types
        if (version >= 11) {
            metaWriter.writeI32(scriptTypes.length);
            for (st in scriptTypes) {
                metaWriter.writeI32(Reflect.field(st, "localFileIndex"));
                if (version < 14) {
                    metaWriter.writeI32(Std.parseInt(Std.string(Reflect.field(st, "localIdentifierInFile"))));
                } else {
                    metaWriter.alignStream();
                    metaWriter.writeI64Str(Std.string(Reflect.field(st, "localIdentifierInFile")));
                }
            }
        }

        // Externals
        metaWriter.writeI32(externals.length);
        for (ex in externals) {
            if (version >= 6) metaWriter.writeStringToNull(Reflect.field(ex, "tempEmpty"));
            if (version >= 5) {
                if (Reflect.hasField(ex, "guid")) metaWriter.writeBytes(Bytes.ofHex(Reflect.field(ex, "guid")));
                metaWriter.writeI32(Reflect.field(ex, "type"));
            }
            metaWriter.writeStringToNull(Reflect.field(ex, "path"));
        }

        // Ref types (v>=20)
        if (version >= 20) {
            // Not implemented for now — write 0
            metaWriter.writeI32(0);
        }

        // userInformation (v>=5)
        if (version >= 5) {
            metaWriter.writeStringToNull(userInformation == null ? "" : userInformation);
        }

        var metadataBytes = metaWriter.getBytes();
        var metadataSize = metadataBytes.length;

        // Step 3: Compute dataOffset (16-byte aligned)
        // Header: 4*4 + 1 (endian) + 3 (reserved) = 20 bytes (for v < 22)
        var headerSize = (version >= 22) ? 48 : 20;
        var dataOffset = headerSize + metadataSize;
        // Align dataOffset to 16 bytes (Unity convention)
        var rem = dataOffset % 16;
        if (rem != 0) dataOffset += 16 - rem;
        var totalFileSize = dataOffset + dataCursor;

        // Step 4: Now patch the byte_start values in the metadata bytes
        // (we wrote placeholders of 0 above)
        // For each object, find the byte_start field in metadataBytes and patch it.
        // This requires walking the metadata again to find the offsets —
        // easier to just re-write metadata with the correct byte_starts.
        var metaWriter2 = new SFWriter(bigEndian);
        if (version >= 7) metaWriter2.writeStringToNull(unityVersion);
        if (version >= 8) metaWriter2.writeI32(targetPlatform);
        if (version >= 13) metaWriter2.writeBool(enableTypeTree);
        metaWriter2.writeI32(types.length);
        for (t in types) {
            var classID : Int = Reflect.field(t, "classID");
            metaWriter2.writeI32(classID);
            if (version >= 16) metaWriter2.writeBool(Reflect.field(t, "isStrippedType"));
            if (version >= 17) metaWriter2.writeI16(Reflect.field(t, "scriptTypeIndex"));
            if (version >= 13) {
                var needScriptID = (Reflect.field(t, "scriptTypeIndex") != null
                                    && Reflect.field(t, "scriptTypeIndex") >= 0)
                                 || (version < 16 && classID < 0)
                                 || (version >= 16 && classID == 114);
                if (needScriptID && Reflect.hasField(t, "scriptID")) {
                    metaWriter2.writeBytes(Bytes.ofHex(Reflect.field(t, "scriptID")));
                }
                if (Reflect.hasField(t, "oldTypeHash")) {
                    metaWriter2.writeBytes(Bytes.ofHex(Reflect.field(t, "oldTypeHash")));
                }
            }
            if (enableTypeTree && Reflect.hasField(t, "typeTreeBytes")) {
                metaWriter2.writeBytes(Reflect.field(t, "typeTreeBytes"));
            }
            if (version >= 21) {
                var deps : Array<Int> = Reflect.field(t, "typeDependencies");
                if (deps == null) deps = [];
                metaWriter2.writeI32(deps.length);
                for (d in deps) metaWriter2.writeI32(d);
            }
        }
        if (7 <= version && version < 14) {
            metaWriter2.writeI32(0);
        }
        metaWriter2.writeI32(objects.length);
        for (i in 0...objects.length) {
            var o = objects[i];
            if (bigIDEnabled != 0) {
                metaWriter2.writeI64Str(Std.string(Reflect.field(o, "pathID")));
            } else if (version < 14) {
                metaWriter2.writeI32(Std.parseInt(Std.string(Reflect.field(o, "pathID"))));
            } else {
                metaWriter2.alignStream();
                metaWriter2.writeI64Str(Std.string(Reflect.field(o, "pathID")));
            }
            // byte_start = dataOffset + newByteStarts[i] (from data section layout)
            var absStart = dataOffset + newByteStarts[i];
            if (version >= 22) {
                metaWriter2.writeI32(absStart); metaWriter2.writeI32(0);
            } else {
                metaWriter2.writeI32(absStart);
            }
            metaWriter2.writeI32(objBytes[i].length);  // byte_size
            var typeID : Int = Reflect.field(o, "typeID");
            metaWriter2.writeI32(typeID);
            if (version < 16) {
                metaWriter2.writeU16(Reflect.field(o, "classID"));
            }
            if (version < 11) {
                metaWriter2.writeU16(0);
            }
            if (11 <= version && version < 17) {
                var sti : Int = Reflect.field(o, "scriptTypeIndex");
                metaWriter2.writeI16(sti);
            }
            if (version == 15 || version == 16) {
                metaWriter2.writeByte(Reflect.field(o, "isStripped"));
            }
        }
        if (version >= 11) {
            metaWriter2.writeI32(scriptTypes.length);
            for (st in scriptTypes) {
                metaWriter2.writeI32(Reflect.field(st, "localFileIndex"));
                if (version < 14) {
                    metaWriter2.writeI32(Std.parseInt(Std.string(Reflect.field(st, "localIdentifierInFile"))));
                } else {
                    metaWriter2.alignStream();
                    metaWriter2.writeI64Str(Std.string(Reflect.field(st, "localIdentifierInFile")));
                }
            }
        }
        metaWriter2.writeI32(externals.length);
        for (ex in externals) {
            if (version >= 6) metaWriter2.writeStringToNull(Reflect.field(ex, "tempEmpty"));
            if (version >= 5) {
                if (Reflect.hasField(ex, "guid")) metaWriter2.writeBytes(Bytes.ofHex(Reflect.field(ex, "guid")));
                metaWriter2.writeI32(Reflect.field(ex, "type"));
            }
            metaWriter2.writeStringToNull(Reflect.field(ex, "path"));
        }
        if (version >= 20) {
            metaWriter2.writeI32(0);
        }
        if (version >= 5) {
            metaWriter2.writeStringToNull(userInformation == null ? "" : userInformation);
        }
        var metadataBytes2 = metaWriter2.getBytes();
        // Verify metadata size matches
        if (metadataBytes2.length != metadataSize) {
            // Throw — sizes should match
            throw 'Metadata size mismatch: first pass=${metadataSize}, second pass=${metadataBytes2.length}';
        }

        // Step 5: Write the final SerializedFile bytes
        var out = new haxe.io.BytesBuffer();
        // Header (always BE) — manually write 4-byte big-endian i32s
        var _writeBE32 = function(v : Int) : Void {
            out.addByte((v >> 24) & 0xFF); out.addByte((v >> 16) & 0xFF);
            out.addByte((v >> 8) & 0xFF);  out.addByte(v & 0xFF);
        };
        _writeBE32(metadataSize);
        _writeBE32(totalFileSize);
        _writeBE32(version);
        _writeBE32(dataOffset);
        out.addByte(endiannessByte);  // 0 = LE, 1 = BE
        out.addByte(0); out.addByte(0); out.addByte(0);  // reserved[3]
        // (version >= 22: extra header fields — not handled here)
        // Metadata
        out.addBytes(metadataBytes2, 0, metadataBytes2.length);
        // Padding to dataOffset
        var written = 20 + metadataBytes2.length;
        while (written < dataOffset) { out.addByte(0); written++; }
        // Data section — write objects in dataOrder (sorted by original byteStart)
        for (idx in dataOrder) {
            out.addBytes(objBytes[idx], 0, objBytes[idx].length);
            // Align to 8 bytes
            var bufLen = out.length;
            var rem2 = bufLen % 8;
            if (rem2 != 0) for (_ in 0...(8 - rem2)) out.addByte(0);
        }
        return out.getBytes();
    }

    // ── TypeTree-driven value writer ──────────────────────────────────────
    // Port of UnityPy.helpers.TypeTreeHelper.write_value.

    public static function writeValuePublic(node : TypeTreeNode, value : Dynamic, w : SFWriter) : Void {
        writeValue(node, value, w);
    }

    static function writeValue(node : TypeTreeNode, value : Dynamic, w : SFWriter) : Void {
        var align = metaflagIsAligned(node.m_MetaFlag);
        if (writePrimitive(node.m_Type, value, w)) {
            // primitive handled
        } else if (node.m_Type == "pair") {
            writeValue(node.m_Children[0], value[0], w);
            writeValue(node.m_Children[1], value[1], w);
        } else if (node.m_Children.length > 0 && node.m_Children[0].m_Type == "Array") {
            if (metaflagIsAligned(node.m_Children[0].m_MetaFlag)) align = true;
            w.writeI32(value.length);
            var subtype = node.m_Children[0].m_Children[1];
            var arr : Array<Dynamic> = value;
            for (subValue in arr) writeValue(subtype, subValue, w);
        } else {
            // Class
            for (child in node.m_Children) {
                if (Reflect.hasField(value, child.m_Name)) {
                    writeValue(child, Reflect.field(value, child.m_Name), w);
                }
            }
        }
        if (align) w.alignStream();
    }

    static function writePrimitive(type : String, value : Dynamic, w : SFWriter) : Bool {
        return switch (type) {
            case "SInt8":               w.writeByte(Std.int(value) & 0xFF); true;
            case "UInt8", "char":        w.writeByte(Std.int(value) & 0xFF); true;
            case "short", "SInt16":      w.writeI16(Std.int(value)); true;
            case "unsigned short", "UInt16": w.writeU16(Std.int(value)); true;
            case "int", "SInt32":        w.writeI32(Std.int(value)); true;
            case "unsigned int", "UInt32", "Type*": w.writeU32(Std.int(value)); true;
            case "long long", "SInt64":  w.writeI64Str(Std.string(value)); true;
            case "unsigned long long", "UInt64", "FileSize": w.writeI64Str(Std.string(value)); true;
            case "float":                w.writeF32(Std.parseFloat(Std.string(value))); true;
            case "double":               w.writeF64(Std.parseFloat(Std.string(value))); true;
            case "bool":                 w.writeBool(value == true || value == "true" || value == 1); true;
            case "string":               w.writeAlignedString(Std.string(value)); true;
            case "TypelessData":
                // value is a hex string — convert back to bytes
                var b = Bytes.ofHex(Std.string(value));
                w.writeI32(b.length);
                w.writeBytes(b);
                true;
            default: false;
        };
    }
}

// ── Data types ─────────────────────────────────────────────────────────────

class SerializedType {
    public var classID : Int;
    public var isStrippedType : Bool = false;
    public var scriptTypeIndex : Int = -1;
    public var scriptID : Null<Bytes> = null;
    public var oldTypeHash : Null<Bytes> = null;
    public var typeTree : Null<TypeTree> = null;
    public var m_ClassName : String = "";
    public var m_NameSpace : String = "";
    public var m_AssemblyName : String = "";
    public var typeDependencies : Array<Int> = [];
    public function new() {}
}

class ObjectInfo {
    public var pathID : String;
    public var byteStart : Int;
    public var byteSize : Int;
    public var typeID : Int;
    public var classID : Int;
    public var serializedType : Null<SerializedType> = null;
    public var scriptTypeIndex : Int = -1;
    public var isStripped : Int = 0;
    public var pathIDStr(get, null) : String;
    function get_pathIDStr() : String return pathID;
    public function new() {}
}

class TypeTree {
    public var root : TypeTreeNode;
    public var allNodes : Array<TypeTreeNode>;
    public var stringBuffer : Bytes;
    public var rawBytes : Null<Bytes> = null;  // captured during parse, used by save() to preserve byte-exact metadata
    public function new() {}
}

class TypeTreeNode {
    public var m_Level : Int = 0;
    public var m_Type : String = "";
    public var m_Name : String = "";
    public var m_ByteSize : Int = 0;
    public var m_Version : Int = 0;
    public var m_TypeFlags : Int = 0;
    public var m_TypeStrOff : Int = 0;
    public var m_NameStrOff : Int = 0;
    public var m_Index : Int = 0;
    public var m_MetaFlag : Int = 0;
    public var m_Children : Array<TypeTreeNode> = [];
    public function new() {}
}

// ── Endian-switchable binary reader for Unity SerializedFile ─────────────

class SFReader {
    var bi : BytesInput;
    var origBytes : Bytes;  // reference to original bytes for getBytesRange()
    var be : Bool;

    public function new(b : Bytes, bigEndian : Bool = true) {
        bi = new BytesInput(b);
        bi.bigEndian = bigEndian;
        be = bigEndian;
        origBytes = b;
    }
    public function setEndian(bigEndian : Bool) : Void {
        bi.bigEndian = bigEndian;
        be = bigEndian;
    }
    public function isBE() : Bool return be;

    public function readU32()  : Int   { return bi.readInt32(); }
    public function readI32()  : Int   { return bi.readInt32(); }
    public function readI16()  : Int   { return bi.readInt16(); }
    public function readU16()  : Int   { return bi.readUInt16(); }
    public function readByte() : Int  { return bi.readByte(); }
    public function readBool() : Bool { return bi.readByte() != 0; }
    public function readF32()  : Float { return bi.readFloat(); }
    public function readF64()  : Float { return bi.readDouble(); }
    public function readBytes(n : Int) : Bytes { return bi.read(n); }
    public function readI64Str() : String {
        var hi = bi.readInt32();
        var lo = bi.readInt32();
        // Convert to signed string
        if (be) {
            // hi is the high 32 bits
            return haxe.Int64.toStr(haxe.Int64.make(hi, lo));
        } else {
            // On LE, BytesInput.readUInt32 reads as if BE due to bigEndian flag,
            // but for I64 we read hi then lo — which is wrong for LE.
            // Actually BytesInput respects bigEndian, so for LE we need to read
            // lo first then hi.
            return haxe.Int64.toStr(haxe.Int64.make(lo, hi));
        }
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
    public function readAlignedString() : String {
        // Aligned string: 4-byte length + bytes + null terminator + align to 4
        var len = bi.readInt32();
        var s = "";
        if (len > 0 && len < bi.length - bi.position) {
            var bb = bi.read(len);
            s = bb.getString(0, len);
            // Read null terminator
            if (bi.position < bi.length) bi.readByte();
            // Align to 4 bytes
            var pos = bi.position;
            var rem = pos % 4;
            if (rem != 0) bi.position += 4 - rem;
        }
        return s;
    }
    public function alignStream() : Void {
        var pos = bi.position;
        var rem = pos % 4;
        if (rem != 0) bi.position += 4 - rem;
    }
    public function skip(n : Int) : Void { bi.position += n; }
    public function remaining() : Int { return bi.length - bi.position; }
    public function position() : Int { return bi.position; }
    public function getBytesRange(start : Int, end : Int) : Bytes {
        var len = end - start;
        if (start < 0 || len < 0 || start + len > origBytes.length) return Bytes.alloc(0);
        return origBytes.sub(start, len);
    }
}

// ── Endian-switchable binary writer for re-serializing Unity SerializedFile ─

class SFWriter {
    var buf : haxe.io.BytesBuffer;
    var be  : Bool;

    public function new(bigEndian : Bool = true) {
        buf = new haxe.io.BytesBuffer();
        be = bigEndian;
    }
    public function setEndian(bigEndian : Bool) : Void { be = bigEndian; }
    public function isBE() : Bool return be;

    public function writeByte(b : Int) : Void { buf.addByte(b & 0xFF); }
    public function writeBytes(b : Bytes) : Void { buf.addBytes(b, 0, b.length); }
    public function writeI16(v : Int) : Void {
        if (be) { buf.addByte((v >> 8) & 0xFF); buf.addByte(v & 0xFF); }
        else    { buf.addByte(v & 0xFF); buf.addByte((v >> 8) & 0xFF); }
    }
    public function writeU16(v : Int) : Void { writeI16(v); }
    public function writeI32(v : Int) : Void {
        if (be) {
            buf.addByte((v >> 24) & 0xFF); buf.addByte((v >> 16) & 0xFF);
            buf.addByte((v >> 8) & 0xFF);  buf.addByte(v & 0xFF);
        } else {
            buf.addByte(v & 0xFF);          buf.addByte((v >> 8) & 0xFF);
            buf.addByte((v >> 16) & 0xFF);  buf.addByte((v >> 24) & 0xFF);
        }
    }
    public function writeU32(v : Int) : Void { writeI32(v); }
    public function writeI64Str(s : String) : Void {
        // Parse string -> Int64 -> 2 × i32
        var i64 = haxe.Int64.parseString(s);
        var hi = i64.high;
        var lo = i64.low;
        if (be) {
            writeI32(hi); writeI32(lo);
        } else {
            writeI32(lo); writeI32(hi);
        }
    }
    public function writeF32(v : Float) : Void {
        writeI32(haxe.io.FPHelper.floatToI32(v));
    }
    public function writeF64(v : Float) : Void {
        var i64 = haxe.io.FPHelper.doubleToI64(v);
        if (be) { writeI32(i64.high); writeI32(i64.low); }
        else    { writeI32(i64.low);  writeI32(i64.high); }
    }
    public function writeBool(v : Bool) : Void { buf.addByte(v ? 1 : 0); }
    public function writeStringToNull(s : String) : Void {
        var b = Bytes.ofString(s);
        for (i in 0...b.length) buf.addByte(b.get(i));
        buf.addByte(0);
    }
    /** Aligned string: 4-byte length + bytes + null terminator + align to 4.
        For length=0, just writes the 4-byte length (no data, no null, no padding) —
        matches Unity's read_aligned_string which returns "" without reading more. */
    public function writeAlignedString(s : String) : Void {
        var b = Bytes.ofString(s);
        writeI32(b.length);
        if (b.length > 0) {
            for (i in 0...b.length) buf.addByte(b.get(i));
            buf.addByte(0);  // null terminator
            // Align to 4
            var pos = buf.length;
            var rem = pos % 4;
            if (rem != 0) for (_ in 0...(4 - rem)) buf.addByte(0);
        }
        // For length=0, position is already 4-byte aligned (we wrote exactly 4 bytes).
    }
    public function alignStream() : Void {
        var pos = buf.length;
        var rem = pos % 4;
        if (rem != 0) for (_ in 0...(4 - rem)) buf.addByte(0);
    }
    public function alignTo(n : Int) : Void {
        var pos = buf.length;
        var rem = pos % n;
        if (rem != 0) for (_ in 0...(n - rem)) buf.addByte(0);
    }
    public function getBytes() : Bytes { return buf.getBytes(); }
    public var length(get, null) : Int;
    function get_length() : Int { return buf.length; }
}
