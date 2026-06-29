package;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/**
 * Packs the deep folder structure back to a binary .pcf.
 * For every asset type it knows the canonical file names written by Unpacker,
 * and rebuilds the exact meta/data bytes from those files.
 * The round-trip is lossless because the raw binary files (_raw.bin, .bin)
 * are always preserved alongside the human-readable versions.
 */
class Packer {

    public static function run(inDir : String, pcfPath : String) : Void {
        Sys.println('Packing: $inDir  →  $pcfPath');
        if (!FS.exists(inDir)) die('Input folder not found: $inDir');

        // ── Header ──────────────────────────────────────────────────────────
        var hj       = FS.readJson(FS.join(inDir, "header.json"));
        var version  : Int = iF(hj, "version");
        var fileType : Int = iF(hj, "fileType");

        // ── Node block ──────────────────────────────────────────────────────
        var nodePayload : Null<Bytes> = null;
        var ntPath = FS.join(FS.join(inDir, "nodes"), "node_tree.json");
        if (FS.exists(ntPath)) {
            nodePayload = serializeNodePayload(jsonToNodeRec(FS.readJson(ntPath)));
        }

        // ── Resource blocks ─────────────────────────────────────────────────
        var resPayloads : Array<{ rt: Int, payload: Bytes }> = [];
        var resRoot = FS.join(inDir, "resources");
        if (FS.exists(resRoot)) {
            for (typeName in FS.subdirs(resRoot)) {
                var typeDir = FS.join(resRoot, typeName);
                var biPath  = FS.join(typeDir, "block_info.json");
                if (!FS.exists(biPath)) continue;
                var bi  = FS.readJson(biPath);
                var rt  = RT.fromName(sF(bi, "resourceType"));
                var payload = serializeResPayload(typeDir, rt);
                resPayloads.push({ rt: rt, payload: payload });
            }
        }

        // ── Compute wrapped block sizes → INDEX offsets ──────────────────────
        var toWrap : Array<{ bt: Int, rt: Int, payload: Bytes }> = [];
        if (nodePayload != null)
            toWrap.push({ bt: PCFBlockTypes.NODE, rt: RT.NODE, payload: nodePayload });
        for (rp in resPayloads)
            toWrap.push({ bt: PCFBlockTypes.RESOURCE, rt: rp.rt, payload: rp.payload });

        // wrapped size = 4(chunkLen) + 4(blockType) + [4(resType) if RESOURCE] + payload
        var wrappedSizes : Array<Int> = [];
        for (w in toWrap) {
            var inner = 4 + (w.bt == PCFBlockTypes.RESOURCE ? 4 : 0) + w.payload.length;
            wrappedSizes.push(4 + inner);
        }

        // INDEX block: payload = 4(blockType) + N*8
        var N = toWrap.length;
        var indexPayloadLen = 4 + N * 8;
        var indexBlockSize  = 4 + indexPayloadLen;

        var cursor = 12 + indexBlockSize;
        var entries : Array<{ rt: Int, offset: Int }> = [];
        for (i in 0...toWrap.length) {
            entries.push({ rt: toWrap[i].rt, offset: cursor });
            cursor += wrappedSizes[i];
        }

        var indexBytes = buildIndexBlock(entries);

        // ── Assemble ─────────────────────────────────────────────────────────
        var fileLength = cursor - 12;
        var w = new BinWriter();
        w.writeI32(version);
        w.writeI32(fileLength);
        w.writeI32(fileType);
        w.writeBytes(indexBytes);
        for (i in 0...toWrap.length) {
            var blk = toWrap[i];
            var cl  = 4 + (blk.bt == PCFBlockTypes.RESOURCE ? 4 : 0) + blk.payload.length;
            w.writeI32(cl);
            w.writeI32(blk.bt);
            if (blk.bt == PCFBlockTypes.RESOURCE) w.writeI32(blk.rt);
            w.writeBytes(blk.payload);
        }

        var finalBytes = w.get();
        var outParent  = haxe.io.Path.directory(pcfPath);
        if (outParent != "" && !FS.exists(outParent)) FS.mkdirs(outParent);
        File.saveBytes(pcfPath, finalBytes);
        Sys.println('  Written ${finalBytes.length} bytes to $pcfPath');
        Sys.println('Done.');
    }

    // ── INDEX ────────────────────────────────────────────────────────────────

    static function buildIndexBlock(entries : Array<{ rt: Int, offset: Int }>) : Bytes {
        var pw = new BinWriter();
        pw.writeI32(PCFBlockTypes.INDEX);
        for (e in entries) { pw.writeI32(e.rt); pw.writeI32(e.offset); }
        var payload = pw.get();
        var w = new BinWriter();
        w.writeI32(payload.length);
        w.writeBytes(payload);
        return w.get();
    }

    // ── Node block ────────────────────────────────────────────────────────────

    static function jsonToNodeRec(j : Dynamic) : NodeRec2 {
        var kids : Array<Dynamic> = Reflect.field(j, "children");
        var children : Array<NodeRec2> = [];
        if (kids != null) for (k in kids) children.push(jsonToNodeRec(k));
        return {
            resType:     RT.fromName(sF(j, "resourceType")),
            referenceID: FS.unhex8(sF(j, "referenceID")),
            name:        sF(j, "name"),
            children:    children
        };
    }

    static function serializeNodePayload(root : NodeRec2) : Bytes {
        var w = new BinWriter(); writeNodeRec(w, root); return w.get();
    }

    static function writeNodeRec(w : BinWriter, n : NodeRec2) : Void {
        var nb = Bytes.ofString(n.name);
        w.writeI32(n.children.length);
        w.writeI32(n.resType);
        w.writeI32(n.referenceID);
        w.writeI32(nb.length);
        w.writeBytes(nb);
        for (c in n.children) writeNodeRec(w, c);
    }

    // ── Resource block ────────────────────────────────────────────────────────

    static function serializeResPayload(typeDir : String, rt : Int) : Bytes {
        // Collect asset dirs sorted by order field
        var assetDirs = FS.subdirs(typeDir);
        var ordered : Array<{ dir: String, order: Int }> = [];
        for (hexID in assetDirs) {
            var d  = FS.join(typeDir, hexID);
            var ap = FS.join(d, "asset_info.json");
            if (!FS.exists(ap)) continue;
            ordered.push({ dir: d, order: iF(FS.readJson(ap), "order") });
        }
        ordered.sort((a, b) -> a.order - b.order);

        var w = new BinWriter();
        w.writeI32(ordered.length);
        for (entry in ordered) serializeAsset(w, entry.dir, rt);
        return w.get();
    }

    static function serializeAsset(w : BinWriter, assetDir : String, rt : Int) : Void {
        var ai      = FS.readJson(FS.join(assetDir, "asset_info.json"));
        var ridInt  = FS.unhex8(sF(ai, "resourceID"));
        var streamed = bF(ai, "streamed");
        var mdType   = iF(ai, "metaDataType");

        var meta : Null<Bytes> = readMeta(assetDir, rt, mdType);
        var data : Null<Bytes> = readData(assetDir, rt);

        var mdLen = meta != null ? meta.length : 0;
        var rdLen = data != null ? data.length : 0;
        var ap    = 4 + 1 + 4 + 4 + mdLen + rdLen;

        w.writeI32(ap);
        w.writeI32(ridInt);
        w.writeBool(streamed);
        w.writeI32(mdType);
        w.writeI32(mdLen);
        if (mdLen > 0) w.writeBytes(meta);
        if (rdLen > 0) w.writeBytes(data);
    }

    // ── Meta reconstruction per type ─────────────────────────────────────────

    static function readMeta(d : String, rt : Int, mdType : Int) : Null<Bytes> {
        // TRANSFORM, CAMERA, LIGHT — no meta, data-only types
        if (rt == RT.TRANSFORM || rt == RT.CAMERA || rt == RT.LIGHT ||
            rt == RT.MATERIALPOINTER || rt == RT.COLLIDER) return null;

        // SCRIPT — re-encode JSON directly (trivial single-field JSON)
        if (rt == RT.SCRIPT)
            return compactJsonBytes(d, "script.json");

        if (rt == RT.MESH)
            return readMetaRaw(d, "mesh_meta.json");

        if (rt == RT.SKINNEDMESH)
            return readMetaRaw(d, "skinnedmesh_meta.json");

        if (rt == RT.TEXTURE)
            return readMetaRaw(d, "texture_meta.json");

        if (rt == RT.AUDIO)
            return readMetaRaw(d, "audio_meta.json");

        if (rt == RT.LIGHTPROBES)
            return readMetaRaw(d, "lightprobes_meta.json");

        if (rt == RT.MATERIAL) {
            // Prefer the original raw bytes for lossless round-trip.
            // Delete material_meta.bin to make the packer encode from material_data.json.
            var raw = tryRead(d, "material_meta.bin");
            if (raw != null) return raw;
            return encodeMaterial(d);
        }
        if (rt == RT.TRANSFORMPOINTER)
            return readMetaRaw(d, "transformpointer_meta.json");

        if (rt == RT.INTERNALBUNDLE)
            return readMetaRaw(d, "bundle_meta.json");

        if (rt == RT.ANIMATOR)
            return readMetaRaw(d, "animator.json");

        if (rt == RT.AVATARREFERENCE)
            return readMetaRaw(d, "avatar.json");

        if (rt == RT.PRIMITIVE)
            return encodePrimitiveMeta(d);

        // CLASS/GRADIENT/GRIDCLUSTER — re-encode from decoded *_info.json
        if (rt == RT.CLASS)
            return encodeSerializedFieldData(d, "class_info.json");

        if (rt == RT.GRADIENT)
            return encodeSerializedFieldData(d, "gradient_info.json");

        if (rt == RT.GRIDCLUSTER)
            return encodeSerializedFieldData(d, "gridcluster_info.json");

        // COLLECTION/POINTERCOLLECTION — re-encode from collection_info.json
        if (rt == RT.COLLECTION || rt == RT.POINTERCOLLECTION)
            return encodeSerializedCollectionData(d, "collection_info.json");

        if (rt == RT.WEIGHTS)
            return readMetaRaw(d, "weights_meta.json");

        if (rt == RT.ANIMATION) {
            var jb = readMetaRaw(d, "animation_meta.json");
            if (jb != null) return jb;
            return tryRead(d, "animation_meta.bin");
        }

        if (rt == RT.ANIMATIONCLIP)
            return readMetaRaw(d, "clip_meta.json");

        if (rt == RT.ANIMATIONCLIPREFERENCE)
            return readMetaRaw(d, "clipref_meta.json");

        if (rt == RT.ANIMATIONLOADER)
            return tryRead(d, "animloader_meta.bin");

        // Generic fallback
        for (ext in ["json", "pb", "bin"]) {
            var p = FS.join(d, 'meta.$ext');
            if (FS.exists(p)) return FS.readBytes(p);
        }
        return null;
    }

    // ── Data reconstruction per type ──────────────────────────────────────────

    static function readData(d : String, rt : Int) : Null<Bytes> {
        // TRANSFORM — re-encode from transform.json: position, rotation, scale → 9×float32 LE
        if (rt == RT.TRANSFORM)
            return encodeFloatData(d, "transform.json", ["position","rotation","scale"]);

        // CAMERA — re-encode from camera.json: bgColor + fieldOfView + aspect → 6×float32 LE
        if (rt == RT.CAMERA)
            return encodeCameraData(d);

        // LIGHT — re-encode from light.json: color + lightType + intensity → 6×float32 LE
        if (rt == RT.LIGHT)
            return encodeLightData(d);

        if (rt == RT.MESH || rt == RT.SKINNEDMESH) {
            // Prefer original binary for lossless round-trip.
            // If mesh_data.bin is absent (user deleted it to apply OBJ edits),
            // re-encode from mesh.obj + mesh_info.json.
            var raw = tryRead(d, "mesh_data.bin");
            if (raw != null) return raw;
            return encodeMeshFromObj(d, rt == RT.SKINNEDMESH);
        }

        if (rt == RT.TEXTURE)
            return tryRead(d, "texture_data.bin");

        if (rt == RT.AUDIO)
            return tryRead(d, "audio_data.bin");

        if (rt == RT.LIGHTPROBES)
            return tryRead(d, "data.bin");

        if (rt == RT.INTERNALBUNDLE)
            return tryRead(d, "bundle_data.bin");

        if (rt == RT.AVATARREFERENCE)
            return tryRead(d, "data.bin");

        if (rt == RT.MATERIALPOINTER)
            return tryRead(d, "pointer_raw.bin");

        if (rt == RT.TRANSFORMPOINTER)
            return tryRead(d, "pointer_raw.bin");

        if (rt == RT.PRIMITIVE)
            return encodePrimitiveData(d);

        if (rt == RT.GRIDCLUSTER)
            return tryRead(d, "gridcluster_data.bin");

        if (rt == RT.WEIGHTS)
            return encodeWeightsData(d);

        if (rt == RT.ANIMATION)
            return tryRead(d, "animation_data.bin");

        if (rt == RT.ANIMATIONCLIP)
            return encodeAnimationClip(d);

        if (rt == RT.ANIMATIONCLIPREFERENCE)
            return tryRead(d, "pointer_raw.bin");

        if (rt == RT.ANIMATIONLOADER)
            return tryRead(d, "animloader_data.bin");

        // Types with no data
        if (rt == RT.COLLIDER || rt == RT.SCRIPT || rt == RT.MATERIAL ||
            rt == RT.ANIMATOR || rt == RT.COLLECTION || rt == RT.POINTERCOLLECTION ||
            rt == RT.CLASS || rt == RT.GRADIENT) return null;

        // Generic fallback
        return tryRead(d, "data.bin");
    }

    // ── File helpers ──────────────────────────────────────────────────────────

    // ── Re-encoding helpers ───────────────────────────────────────────────────

    /**
     * Re-encode TRANSFORM data from transform.json.
     * Reads x_bits/y_bits/z_bits for lossless round-trip; falls back to float values.
     */
    static function encodeFloatData(d : String, jsonFile : String, vecKeys : Array<String>) : Null<Bytes> {
        var p = FS.join(d, jsonFile);
        if (!FS.exists(p)) return null;
        var j = FS.readJson(p);
        var w = new BinWriter();
        for (key in vecKeys) {
            var v = Reflect.field(j, key);
            w.writeI32(floatBits(v, "x", "x_bits"));
            w.writeI32(floatBits(v, "y", "y_bits"));
            w.writeI32(floatBits(v, "z", "z_bits"));
        }
        return w.get();
    }

    /**
     * Re-encode CAMERA data from camera.json.
     * Uses _bits fields for exact round-trip where present.
     */
    static function encodeCameraData(d : String) : Null<Bytes> {
        var p = FS.join(d, "camera.json");
        if (!FS.exists(p)) return null;
        var j = FS.readJson(p);
        var bg = Reflect.field(j, "bgColor");
        var w = new BinWriter();
        w.writeI32(floatBits(bg, "r", "r_bits"));
        w.writeI32(floatBits(bg, "g", "g_bits"));
        w.writeI32(floatBits(bg, "b", "b_bits"));
        w.writeI32(floatBits(bg, "a", "a_bits"));
        w.writeI32(floatFieldBits(Reflect.field(j, "fieldOfView")));
        w.writeI32(floatFieldBits(Reflect.field(j, "aspect")));
        return w.get();
    }

    /**
     * Re-encode LIGHT data from light.json.
     * Uses _bits fields for exact round-trip where present.
     */
    static function encodeLightData(d : String) : Null<Bytes> {
        var p = FS.join(d, "light.json");
        if (!FS.exists(p)) return null;
        var j = FS.readJson(p);
        var c = Reflect.field(j, "color");
        var w = new BinWriter();
        w.writeI32(floatBits(c, "r", "r_bits"));
        w.writeI32(floatBits(c, "g", "g_bits"));
        w.writeI32(floatBits(c, "b", "b_bits"));
        w.writeI32(floatBits(c, "a", "a_bits"));
        // lightType stored as float cast from int
        w.writeI32(haxe.io.FPHelper.floatToI32(iF(j, "lightType") * 1.0));
        // intensity
        w.writeI32(floatFieldBits(Reflect.field(j, "intensity")));
        return w.get();
    }

    /**
     * Re-encode mesh.obj + mesh_info.json → MeshBakingUtilities binary.
     * Mirrors WriteMesh(mesh, saveTangents=true, writeSkinning) exactly.
     *
     * OBJ format used (as written by the unpacker):
     *   v  x y z          — positions
     *   vn nx ny nz        — normals
     *   vt u v             — UVs
     *   f  i/i/i ...       — triangles (1-based, pos/uv/normal indices all equal per vertex)
     *
     * Binary layout (LE):
     *   uint16 vertexCount
     *   uint16 triCount
     *   [uint16 bindposeCount]  — only if skinning
     *   uint8  flags            — always 0x0f (pos|normals|tangents|uv)
     *   WriteVector3Array16bit(positions)
     *   WriteVector3ArrayBytes(normals)    — byte quantised v*127+128
     *   WriteVector4ArrayBytes(tangents)   — computed from normals (all zero w=1)
     *   WriteVector2Array16bit(uvs)
     *   [skinning data]
     *   uint16[] indices
     *   uint16 blendShapeCount (0 — OBJ has no blend shapes)
     *   WriteVector3Array16bit([bounds.center, bounds.size])
     *   [color data — omitted]
     *
     * Tangents are not stored in OBJ. We synthesise them as (0,0,0,1) per
     * vertex — this matches what Unity recalculates on import and is
     * sufficient for most shaders. For skinned meshes the skinning data
     * (bindposes + bone weights) is read from mesh_skinning.json.
     */
    static function encodeMeshFromObj(d : String, isSkinned : Bool) : Null<Bytes> {
        var objPath  = FS.join(d, "mesh.obj");
        var infoPath = FS.join(d, "mesh_info.json");
        if (!FS.exists(objPath)) return null;

        // ── Parse OBJ ──────────────────────────────────────────────────────
        var rawPositions : Array<Array<Float>> = [];
        var rawNormals   : Array<Array<Float>> = [];
        var rawUVs       : Array<Array<Float>> = [];

        // Each triangle is stored as three (posIdx, uvIdx, normIdx) tuples (0-based).
        // Fan-triangulation converts quads and n-gons on the fly so this always
        // ends up as pure triangles regardless of the input face topology.
        var triangles : Array<Array<Int>> = [];  // triangles[t] = [p0,u0,n0, p1,u1,n1, p2,u2,n2]

        for (line in sys.io.File.getContent(objPath).split("\n")) {
            var s = StringTools.trim(line);
            if (s.length == 0 || s.charAt(0) == '#') continue;
            var parts = s.split(" ").filter(function(x) return x != "");
            if (parts.length == 0) continue;
            switch (parts[0]) {
                case "v":
                    // OBJ was exported with X negated for right-handed viewers.
                    // Negate X again to restore Unity left-handed coordinates.
                    rawPositions.push([
                        -Std.parseFloat(parts[1]),
                        Std.parseFloat(parts[2]),
                        Std.parseFloat(parts[3])
                    ]);
                case "vn":
                    rawNormals.push([
                        -Std.parseFloat(parts[1]),
                        Std.parseFloat(parts[2]),
                        Std.parseFloat(parts[3])
                    ]);
                case "vt":
                    rawUVs.push([
                        Std.parseFloat(parts[1]),
                        Std.parseFloat(parts[2])
                    ]);
                case "f":
                    // Parse all vertex tokens for this face, then fan-triangulate:
                    //   (v0,v1,v2), (v0,v2,v3), (v0,v3,v4), …
                    // This handles triangles, quads, and arbitrary n-gons correctly.
                    var faceVerts : Array<Array<Int>> = [];
                    for (fi in 1...parts.length) {
                        var tok = parts[fi].split("/");
                        var pi = Std.parseInt(tok[0]) - 1;
                        var ui = tok.length > 1 && tok[1] != "" ? Std.parseInt(tok[1]) - 1 : 0;
                        var ni = tok.length > 2 && tok[2] != "" ? Std.parseInt(tok[2]) - 1 : 0;
                        faceVerts.push([pi, ui, ni]);
                    }
                    // Fan-triangulate: anchor = faceVerts[0]
                    for (fi in 1...faceVerts.length - 1) {
                        var v0 = faceVerts[0];
                        var v1 = faceVerts[fi];
                        var v2 = faceVerts[fi + 1];
                        triangles.push([v0[0],v0[1],v0[2], v1[0],v1[1],v1[2], v2[0],v2[1],v2[2]]);
                    }
                default:
            }
        }

        // ── Expand to per-vertex arrays (indexed by position index) ────────
        var vc = rawPositions.length;
        var tc = triangles.length;

        var positions : Array<Array<Float>> = rawPositions;
        var normals   : Array<Array<Float>> = [for (_ in 0...vc) [0.0, 0.0, 1.0]];
        var uvs       : Array<Array<Float>> = [for (_ in 0...vc) [0.0, 0.0]];
        var indices   : Array<Int>          = [];

        // The OBJ was exported with reversed winding (a c b) to compensate for
        // the X-flip. Restore original Unity winding (a b c) by swapping back.
        // Fan-triangulation above always produces triangles as (v0, vN, vN+1) —
        // i.e. the OBJ file order is (a, c, b) for each resulting triangle —
        // so the unswap is applied uniformly here regardless of face topology.
        for (tri in triangles) {
            // tri = [p0,u0,n0, p1,u1,n1, p2,u2,n2]
            // OBJ file order per triangle: a(slot 0), c(slot 3), b(slot 6)
            var pi0 = tri[0]; var ui0 = tri[1]; var ni0 = tri[2]; // a
            var pi1 = tri[3]; var ui1 = tri[4]; var ni1 = tri[5]; // c (in file)
            var pi2 = tri[6]; var ui2 = tri[7]; var ni2 = tri[8]; // b (in file)
            if (ni0 < rawNormals.length) normals[pi0] = rawNormals[ni0];
            if (ui0 < rawUVs.length)     uvs[pi0]     = rawUVs[ui0];
            if (ni1 < rawNormals.length) normals[pi1] = rawNormals[ni1];
            if (ui1 < rawUVs.length)     uvs[pi1]     = rawUVs[ui1];
            if (ni2 < rawNormals.length) normals[pi2] = rawNormals[ni2];
            if (ui2 < rawUVs.length)     uvs[pi2]     = rawUVs[ui2];
            // Push as a, b, c (swap c and b back to restore Unity winding)
            indices.push(pi0); // a
            indices.push(pi2); // b (was third in file)
            indices.push(pi1); // c (was second in file)
        }

        // ── Build binary ───────────────────────────────────────────────────
        var skinning : Dynamic = null;
        var bindposeCount = 0;
        if (isSkinned) {
            var skPath = FS.join(d, "mesh_skinning.json");
            if (FS.exists(skPath)) {
                skinning = FS.readJson(skPath);
                var bp : Array<Dynamic> = Reflect.field(skinning, "bindposes");
                bindposeCount = bp != null ? bp.length : 0;
            }
            // write bindposeCount as uint16 after triCount
            // We already wrote vc|tc — need to redo this properly with a real writer
        }

        // Redo with proper uint16 writes
        var w2 = new BinWriter();
        writeU16(w2, vc);
        writeU16(w2, tc);
        if (isSkinned) writeU16(w2, bindposeCount);
        // flags: pos(1) | normals(2) | tangents(4) | uv(8) = 0x0f
        var flagsByte = Bytes.alloc(1); flagsByte.set(0, 0x0f);
        w2.writeBytes(flagsByte);

        // WriteVector3Array16bit(positions)
        writeVec3Array16bit(w2, positions);

        // WriteVector3ArrayBytes(normals) — v*127+128
        for (n in normals) {
            var b3 = Bytes.alloc(3);
            b3.set(0, clampByte(n[0] * 127.0 + 128.0));
            b3.set(1, clampByte(n[1] * 127.0 + 128.0));
            b3.set(2, clampByte(n[2] * 127.0 + 128.0));
            w2.writeBytes(b3);
        }

        // WriteVector4ArrayBytes(tangents) — synthesised (0,0,0,1) = (128,128,128,255)
        for (_ in 0...vc) {
            var b4 = Bytes.alloc(4);
            b4.set(0, 128); b4.set(1, 128); b4.set(2, 128); b4.set(3, 255);
            w2.writeBytes(b4);
        }

        // WriteVector2Array16bit(uvs)
        writeVec2Array16bit(w2, uvs);

        // Skinning data (if present)
        if (isSkinned && skinning != null) {
            // Bindposes: 16 floats each, row-major
            var bpArr : Array<Dynamic> = Reflect.field(skinning, "bindposes");
            if (bpArr != null) {
                for (bp in bpArr) {
                    var mat : Array<Dynamic> = Reflect.field(bp, "matrix");
                    for (j in 0...16) {
                        w2.writeI32(haxe.io.FPHelper.floatToI32(mat != null ? Std.parseFloat(Std.string(mat[j])) : 0.0));
                    }
                }
            }
            // BoneWeights: 4 floats + 4 uint16s per vertex
            var bwArr : Array<Dynamic> = Reflect.field(skinning, "boneWeights");
            if (bwArr != null) {
                for (bwEntry in bwArr) {
                    var ws  : Array<Dynamic> = Reflect.field(bwEntry, "weights");
                    var bis : Array<Dynamic> = Reflect.field(bwEntry, "boneIdx");
                    for (j in 0...4) {
                        var wf = ws != null ? Std.parseFloat(Std.string(ws[j])) : 0.0;
                        w2.writeI32(haxe.io.FPHelper.floatToI32(wf));
                    }
                    for (j in 0...4) {
                        writeU16(w2, bis != null ? Std.int(bis[j]) : 0);
                    }
                }
            }
        }

        // Indices (uint16)
        for (idx in indices) writeU16(w2, idx);

        // Blend shapes: count=0 (OBJ has none)
        writeU16(w2, 0);

        // Bounds: WriteVector3Array16bit([center, size])
        // Compute from positions
        var minX = positions[0][0]; var maxX = minX;
        var minY = positions[0][1]; var maxY = minY;
        var minZ = positions[0][2]; var maxZ = minZ;
        for (p in positions) {
            if (p[0] < minX) minX = p[0]; if (p[0] > maxX) maxX = p[0];
            if (p[1] < minY) minY = p[1]; if (p[1] > maxY) maxY = p[1];
            if (p[2] < minZ) minZ = p[2]; if (p[2] > maxZ) maxZ = p[2];
        }
        var cx = (minX+maxX)*0.5; var cy = (minY+maxY)*0.5; var cz = (minZ+maxZ)*0.5;
        var sx = maxX-minX;       var sy = maxY-minY;       var sz = maxZ-minZ;
        writeVec3Array16bit(w2, [[cx,cy,cz],[sx,sy,sz]]);

        // No colors (OBJ has none)
        return w2.get();
    }

    /** Write a uint16 little-endian */
    static function writeU16(w : BinWriter, v : Int) : Void {
        var b = Bytes.alloc(2);
        b.set(0, v & 0xFF);
        b.set(1, (v >> 8) & 0xFF);
        w.writeBytes(b);
    }

    /** Clamp float to 0-255 and return as Int */
    static inline function clampByte(v : Float) : Int {
        var i = Std.int(v);
        return i < 0 ? 0 : (i > 255 ? 255 : i);
    }

    /**
     * WriteVector3Array16bit: bounds(minX,maxX,minY,maxY,minZ,maxZ) + uint16*3 per vertex.
     * Bounds built as: start with first point ±0.001, then encapsulate all.
     */
    static function writeVec3Array16bit(w : BinWriter, arr : Array<Array<Float>>) : Void {
        if (arr.length == 0) return;
        var minX = arr[0][0]-0.001; var maxX = arr[0][0]+0.001;
        var minY = arr[0][1]-0.001; var maxY = arr[0][1]+0.001;
        var minZ = arr[0][2]-0.001; var maxZ = arr[0][2]+0.001;
        for (v in arr) {
            if (v[0] < minX) minX = v[0]; if (v[0] > maxX) maxX = v[0];
            if (v[1] < minY) minY = v[1]; if (v[1] > maxY) maxY = v[1];
            if (v[2] < minZ) minZ = v[2]; if (v[2] > maxZ) maxZ = v[2];
        }
        w.writeI32(haxe.io.FPHelper.floatToI32(minX));
        w.writeI32(haxe.io.FPHelper.floatToI32(maxX));
        w.writeI32(haxe.io.FPHelper.floatToI32(minY));
        w.writeI32(haxe.io.FPHelper.floatToI32(maxY));
        w.writeI32(haxe.io.FPHelper.floatToI32(minZ));
        w.writeI32(haxe.io.FPHelper.floatToI32(maxZ));
        var rX = maxX-minX; var rY = maxY-minY; var rZ = maxZ-minZ;
        for (v in arr) {
            var ux = rX > 0 ? clampF((v[0]-minX)/rX * 65535.0) : 0;
            var uy = rY > 0 ? clampF((v[1]-minY)/rY * 65535.0) : 0;
            var uz = rZ > 0 ? clampF((v[2]-minZ)/rZ * 65535.0) : 0;
            writeU16(w, ux); writeU16(w, uy); writeU16(w, uz);
        }
    }

    /**
     * WriteVector2Array16bit: start with first point ±0.001 min/max,
     * then encapsulate all, then quantise.
     */
    static function writeVec2Array16bit(w : BinWriter, arr : Array<Array<Float>>) : Void {
        if (arr.length == 0) return;
        var minU = arr[0][0]-0.001; var maxU = arr[0][0]+0.001;
        var minV = arr[0][1]-0.001; var maxV = arr[0][1]+0.001;
        for (uv in arr) {
            if (uv[0] < minU) minU = uv[0]; if (uv[0] > maxU) maxU = uv[0];
            if (uv[1] < minV) minV = uv[1]; if (uv[1] > maxV) maxV = uv[1];
        }
        w.writeI32(haxe.io.FPHelper.floatToI32(minU));
        w.writeI32(haxe.io.FPHelper.floatToI32(maxU));
        w.writeI32(haxe.io.FPHelper.floatToI32(minV));
        w.writeI32(haxe.io.FPHelper.floatToI32(maxV));
        var rU = maxU-minU; var rV = maxV-minV;
        for (uv in arr) {
            var uu = rU > 0 ? clampF((uv[0]-minU)/rU * 65535.0) : 0;
            var uv2 = rV > 0 ? clampF((uv[1]-minV)/rV * 65535.0) : 0;
            writeU16(w, uu); writeU16(w, uv2);
        }
    }

    static inline function clampF(v : Float) : Int {
        var i = Std.int(v);
        return i < 0 ? 0 : (i > 65535 ? 65535 : i);
    }

    /** Read a float value from an object field, preferring _bits hex for exact bits */
    static function floatBits(obj : Dynamic, valKey : String, bitsKey : String) : Int {
        if (obj == null) return 0;
        var bits = Reflect.field(obj, bitsKey);
        if (bits != null) return FS.unhex8(Std.string(bits));
        return haxe.io.FPHelper.floatToI32(fF(obj, valKey));
    }

    /** Read a {value, bits} object, preferring bits hex */
    static function floatFieldBits(obj : Dynamic) : Int {
        if (obj == null) return 0;
        var bits = Reflect.field(obj, "bits");
        if (bits != null) return FS.unhex8(Std.string(bits));
        return haxe.io.FPHelper.floatToI32(fF(obj, "value"));
    }

    /**
     * Re-encode SerializedMaterial protobuf from material_info.json.
     * Falls back to material_meta.bin if json is absent.
     *
     * Wire layout (from PlotagonAOTSerializer):
     *   field 1  = DisplayName   (string)
     *   field 2  = MaterialName  subitem { f1=CGMaterial, f2=GLSLMaterial }
     *   field 3  = ShaderName    subitem { f1=CGShader, f2=GLSLSHader }
     *   field 4  = repeated map entry subitems { f1=key(string), f2=value subitem }
     *     value subitem = SerializedMaterialProperty:
     *       f100 subitem = VectorProperty  { f1=X, f2=Y, f3=Z, f4=W  (Fixed32) }
     *       f200 subitem = ColorProperty   { f1=R, f2=G, f3=B, f4=A  (Fixed32) }
     *       f300 subitem = FloatProperty   { f1=Val (Fixed32) }
     *       f400 subitem = TextureProperty { f1=ReferenceID (varint uint32) }
     *       f1   = PropertyType (varint) — written AFTER the subtype subitem
     */
    static function encodeMaterial(d : String) : Null<Bytes> {
        var jp = FS.join(d, "material_data.json");
        if (!FS.exists(jp)) return tryRead(d, "material_meta.bin");
        var j = FS.readJson(jp);

        var w = new BinWriter();

        // field 1 — DisplayName
        var dn = sF(j, "displayName");
        if (dn != "") pbWriteLenDelim(w, 1, Bytes.ofString(dn));

        // field 2 — MaterialName subitem
        var mn = Reflect.field(j, "materialName");
        if (mn != null) {
            var sub = new BinWriter();
            var cg = sF(mn, "cg"); if (cg != "") pbWriteLenDelim(sub, 1, Bytes.ofString(cg));
            var gl = sF(mn, "gles"); if (gl != "") pbWriteLenDelim(sub, 2, Bytes.ofString(gl));
            pbWriteLenDelim(w, 2, sub.get());
        }

        // field 3 — ShaderName subitem
        var sn = Reflect.field(j, "shaderName");
        if (sn != null) {
            var sub = new BinWriter();
            var cg = sF(sn, "cg"); if (cg != "") pbWriteLenDelim(sub, 1, Bytes.ofString(cg));
            var gl = sF(sn, "gles"); if (gl != "") pbWriteLenDelim(sub, 2, Bytes.ofString(gl));
            pbWriteLenDelim(w, 3, sub.get());
        }

        // field 4 — repeated property map entries
        var props : Array<Dynamic> = Reflect.field(j, "properties");
        if (props != null) {
            for (prop in props) {
                var name   = sF(prop, "name");
                var ptype  = iF(prop, "type");
                // Build the value subitem (SerializedMaterialProperty)
                // type=0 means name-only slot (no value blob)
                var entryW = new BinWriter();
                if (name != "") pbWriteLenDelim(entryW, 1, Bytes.ofString(name));
                if (ptype != 0) {
                    var valW = new BinWriter();
                    if (ptype == 1) {
                        // FloatType: field 300 subitem { f1=Val Fixed32 }
                        var floatSub = new BinWriter();
                        var v = fF(prop, "value");
                        if (v != 0) pbWriteFixed32(floatSub, 1, haxe.io.FPHelper.floatToI32(v));
                        pbWriteLenDelim(valW, 300, floatSub.get());
                    } else if (ptype == 2) {
                        // VectorType: field 100 subitem { f1=X,f2=Y,f3=Z,f4=W Fixed32 }
                        var vec = Reflect.field(prop, "vector");
                        var vecSub = new BinWriter();
                        if (vec != null) {
                            var x=fF(vec,"x"); var y=fF(vec,"y"); var z=fF(vec,"z"); var vw=fF(vec,"w");
                            if (x != 0) pbWriteFixed32(vecSub, 1, haxe.io.FPHelper.floatToI32(x));
                            if (y != 0) pbWriteFixed32(vecSub, 2, haxe.io.FPHelper.floatToI32(y));
                            if (z != 0) pbWriteFixed32(vecSub, 3, haxe.io.FPHelper.floatToI32(z));
                            if (vw != 0) pbWriteFixed32(vecSub, 4, haxe.io.FPHelper.floatToI32(vw));
                        }
                        pbWriteLenDelim(valW, 100, vecSub.get());
                    } else if (ptype == 3) {
                        // ColorType: field 200 subitem { f1=R,f2=G,f3=B,f4=A Fixed32 }
                        var col = Reflect.field(prop, "color");
                        var colSub = new BinWriter();
                        if (col != null) {
                            var r=fF(col,"r"); var g=fF(col,"g"); var b=fF(col,"b"); var a=fF(col,"a");
                            if (r != 0) pbWriteFixed32(colSub, 1, haxe.io.FPHelper.floatToI32(r));
                            if (g != 0) pbWriteFixed32(colSub, 2, haxe.io.FPHelper.floatToI32(g));
                            if (b != 0) pbWriteFixed32(colSub, 3, haxe.io.FPHelper.floatToI32(b));
                            if (a != 0) pbWriteFixed32(colSub, 4, haxe.io.FPHelper.floatToI32(a));
                        }
                        pbWriteLenDelim(valW, 200, colSub.get());
                    } else if (ptype == 4) {
                        // TextureType: field 400 subitem { f1=ReferenceID varint uint32 }
                        var refHex = sF(prop, "referenceID");
                        var texSub = new BinWriter();
                        if (refHex != "") {
                            pbWriteVarint(texSub, (1 << 3) | 0);
                            pbWriteVarintRaw(texSub, FS.unhex8(refHex));
                        }
                        pbWriteLenDelim(valW, 400, texSub.get());
                    }
                    // PropertyType int at field 1 — written AFTER the subtype subitem
                    pbWriteVarint(valW, (1 << 3) | 0); pbWriteVarint(valW, ptype);
                    pbWriteLenDelim(entryW, 2, valW.get());
                }
                pbWriteLenDelim(w, 4, entryW.get());
            }
        }
        return w.get();
    }

    /**
     * Re-encode PRIMITIVE meta (SerializedFieldData) from primitive_decoded.json.
     * Falls back to primitive_meta.bin.
     * Same wire format as CLASS/GRADIENT but also writes field 1 (type) when non-zero.
     */
    static function encodePrimitiveMeta(d : String) : Null<Bytes> {
        var jp = FS.join(d, "primitive_decoded.json");
        if (!FS.exists(jp)) return tryRead(d, "primitive_meta.bin");
        var j = FS.readJson(jp);
        return encodeSerializedFieldData(d, "primitive_decoded.json");
    }

    /**
     * Re-encode PRIMITIVE data from primitive_decoded.json value field.
     * Falls back to primitive_data.bin for BYTEBUFFER or when json absent.
     *
     * Type encodings:
     *   STRING    → UTF-8 bytes (no length prefix — stored as raw string in data field)
     *   INT       → int32 LE
     *   UINT      → uint32 LE
     *   FLOAT     → float32 LE
     *   DOUBLE    → float64 LE
     *   BOOLEAN   → 1 byte (1=true, 0=false)
     *   BYTEBUFFER→ raw bin (keep primitive_data.bin)
     */
    static function encodePrimitiveData(d : String) : Null<Bytes> {
        var jp = FS.join(d, "primitive_decoded.json");
        if (!FS.exists(jp)) return tryRead(d, "primitive_data.bin");
        var j = FS.readJson(jp);
        var ft = sF(j, "fieldTypeName");
        var val = Reflect.field(j, "value");
        var w = new BinWriter();
        switch (ft) {
            case "STRING":
                if (val == null) return null;
                return Bytes.ofString(Std.string(val));
            case "INT":
                w.writeI32(val == null ? 0 : Std.int(val));
                return w.get();
            case "UINT":
                w.writeI32(val == null ? 0 : Std.int(val));
                return w.get();
            case "FLOAT":
                w.writeI32(haxe.io.FPHelper.floatToI32(val == null ? 0.0 : fF(j, "value")));
                return w.get();
            case "DOUBLE":
                var dv : Float = val == null ? 0.0 : Std.parseFloat(Std.string(val));
                var hi = haxe.io.FPHelper.doubleToI64(dv);
                w.writeI32(hi.low); w.writeI32(hi.high);
                return w.get();
            case "BOOLEAN":
                // 1 byte: 0=false, 1=true (not int32)
                var sv2 = val == null ? "false" : Std.string(val).toLowerCase();
                var bv = (sv2 == "true" || sv2 == "1");
                var b1 = Bytes.alloc(1); b1.set(0, bv ? 1 : 0);
                return b1;
            default: // BYTEBUFFER or unknown
                return tryRead(d, "primitive_data.bin");
        }
    }

    /**
     * Re-encode SerializedAnimationClip from clip_decoded.json.
     * Falls back to clip_data.bin.
     *
     * Wire layout (from PlotagonAOTSerializer):
     *   field 1 = repeated map entry subitem { f1=channelName(varint), f2=repeated KF subitem }
     *   field 2 = PostWrapMode (varint, omitted if 0)
     *   field 3 = PreWrapMode  (varint, omitted if 0)
     *   KF subitem: f1=Time, f2=Value, f3=InTangent, f4=OutTangent (Fixed32, omitted if 0)
     */
    static function encodeAnimationClip(d : String) : Null<Bytes> {
        var jp = FS.join(d, "clip_decoded.json");
        if (!FS.exists(jp)) return tryRead(d, "clip_data.bin");
        var j = FS.readJson(jp);
        var w = new BinWriter();

        var channels : Array<Dynamic> = Reflect.field(j, "channels");
        if (channels != null) {
            for (chan in channels) {
                var chanName = iF(chan, "channelName");
                var keyframes : Array<Dynamic> = Reflect.field(chan, "keyframes");
                var entryW = new BinWriter();
                // f1 = channelName (always written)
                pbWriteVarint(entryW, (1 << 3) | 0); pbWriteVarint(entryW, chanName);
                // f2 = repeated keyframe subitems
                if (keyframes != null) {
                    for (kf in keyframes) {
                        var kfW = new BinWriter();
                        var t  = fF(kf, "time");
                        var v  = fF(kf, "value");
                        var it = fF(kf, "inTangent");
                        var ot = fF(kf, "outTangent");
                        if (t  != 0) pbWriteFixed32(kfW, 1, haxe.io.FPHelper.floatToI32(t));
                        if (v  != 0) pbWriteFixed32(kfW, 2, haxe.io.FPHelper.floatToI32(v));
                        if (it != 0) pbWriteFixed32(kfW, 3, haxe.io.FPHelper.floatToI32(it));
                        if (ot != 0) pbWriteFixed32(kfW, 4, haxe.io.FPHelper.floatToI32(ot));
                        pbWriteLenDelim(entryW, 2, kfW.get());
                    }
                }
                pbWriteLenDelim(w, 1, entryW.get());
            }
        }

        var post = iF(j, "postWrapMode");
        var pre  = iF(j, "preWrapMode");
        if (post != 0) { pbWriteVarint(w, (2 << 3) | 0); pbWriteVarint(w, post); }
        if (pre  != 0) { pbWriteVarint(w, (3 << 3) | 0); pbWriteVarint(w, pre); }
        return w.get();
    }

    /**
     * Re-encode WEIGHTS data from weights_decoded.json.
     * Falls back to weights_data.bin.
     *
     * Format: repeated [ int32_LE length | WeightTable protobuf ]
     * WeightTable fields (omit if zero/null per AOTSerializer):
     *   f1=BoneName0, f2=BoneName1, f3=BoneName2, f4=BoneName3 (strings)
     *   f5=Weight0, f6=Weight1, f7=Weight2, f8=Weight3 (Fixed32 floats)
     */
    static function encodeWeightsData(d : String) : Null<Bytes> {
        var jp = FS.join(d, "weights_decoded.json");
        if (!FS.exists(jp)) return tryRead(d, "weights_data.bin");
        var j = FS.readJson(jp);
        var entries : Array<Dynamic> = Reflect.field(j, "weights");
        if (entries == null) return tryRead(d, "weights_data.bin");
        var out = new BinWriter();
        for (entry in entries) {
            var wt = new BinWriter();
            var b0 = sF(entry, "bone0"); if (b0 != "") pbWriteLenDelim(wt, 1, Bytes.ofString(b0));
            var b1 = sF(entry, "bone1"); if (b1 != "") pbWriteLenDelim(wt, 2, Bytes.ofString(b1));
            var b2 = sF(entry, "bone2"); if (b2 != "") pbWriteLenDelim(wt, 3, Bytes.ofString(b2));
            var b3 = sF(entry, "bone3"); if (b3 != "") pbWriteLenDelim(wt, 4, Bytes.ofString(b3));
            var w0b = Reflect.field(entry,"w0_bits"); var w1b = Reflect.field(entry,"w1_bits");
            var w2b = Reflect.field(entry,"w2_bits"); var w3b = Reflect.field(entry,"w3_bits");
            inline function wbits(bitsField:Dynamic, valKey:String):Int
                return bitsField != null ? FS.unhex8(Std.string(bitsField)) : haxe.io.FPHelper.floatToI32(fF(entry, valKey));
            var i0 = wbits(w0b,"w0"); var i1 = wbits(w1b,"w1"); var i2 = wbits(w2b,"w2"); var i3 = wbits(w3b,"w3");
            if (i0 != 0) pbWriteFixed32(wt, 5, i0);
            if (i1 != 0) pbWriteFixed32(wt, 6, i1);
            if (i2 != 0) pbWriteFixed32(wt, 7, i2);
            if (i3 != 0) pbWriteFixed32(wt, 8, i3);
            var payload = wt.get();
            // int32 LE length prefix
            out.writeI32(payload.length);
            out.writeBytes(payload);
        }
        return out.get();
    }

    /** Write a fixed32 field (WireType 5) */
    static inline function pbWriteFixed32(w : BinWriter, fieldNo : Int, bits : Int) : Void {
        pbWriteVarintRaw(w, (fieldNo << 3) | 5);
        w.writeI32(bits);
    }


    /**
     * Re-encode CLASS/GRADIENT/GRIDCLUSTER meta from *_info.json.
     * Produces a SerializedFieldData protobuf:
     *   field 1 = type        (varint)
     *   field 2 = typeName    (string, only if non-empty)
     *   field 3 = assemblyType(varint)
     *   field 4 = arrayItem   (varint bool, only if true)
     *   field 5 = fieldName   (string)
     */
    static function encodeSerializedFieldData(d : String, infoFile : String) : Null<Bytes> {
        var p = FS.join(d, infoFile);
        if (!FS.exists(p)) return null;
        var j = FS.readJson(p);
        var fieldType    = iF(j, "fieldType");
        var typeName     = sF(j, "typeName");
        var assemblyType = iF(j, "assemblyType");
        var arrayItem    = bF(j, "arrayItem");
        var fieldName    = sF(j, "fieldName");
        var w = new BinWriter();
        if (fieldType != 0) { pbWriteVarint(w, (1 << 3) | 0); pbWriteVarint(w, fieldType); } // field1 only if non-zero
        if (typeName != "") { pbWriteLenDelim(w, 2, Bytes.ofString(typeName)); }               // field2
        pbWriteVarint(w, (3 << 3) | 0); pbWriteVarint(w, assemblyType);                       // field3
        if (arrayItem) { pbWriteVarint(w, (4 << 3) | 0); pbWriteVarint(w, 1); }               // field4
        pbWriteLenDelim(w, 5, Bytes.ofString(fieldName));                                       // field5
        return w.get();
    }

    /**
     * Re-encode COLLECTION/POINTERCOLLECTION meta from collection_info.json.
     * SerializedCollectionData protobuf — fields omitted when default (0/null/empty):
     *   field 1 = type        (varint, omitted if 0)
     *   field 2 = typeName    (string)
     *   field 3 = assemblyType(varint, omitted if 0)
     *   field 4 = count       (varint, omitted if 0)
     *   field 5 = itemIDs     (repeated varint — one WriteFieldHeader(5) per item)
     *   field 6 = fieldName   (string)
     */
    static function encodeSerializedCollectionData(d : String, infoFile : String) : Null<Bytes> {
        var p = FS.join(d, infoFile);
        if (!FS.exists(p)) return null;
        var j = FS.readJson(p);
        var fieldType    = iF(j, "fieldType");
        var typeName     = sF(j, "typeName");
        var assemblyType = iF(j, "assemblyType");
        var count        = iF(j, "count");
        var fieldName    = sF(j, "fieldName");
        var itemIDsArr   : Array<Dynamic> = Reflect.field(j, "itemIDs");
        var w = new BinWriter();
        if (fieldType != 0)    { pbWriteVarint(w, (1 << 3) | 0); pbWriteVarint(w, fieldType); }
        if (typeName != null && typeName != "") pbWriteLenDelim(w, 2, Bytes.ofString(typeName));
        if (assemblyType != 0) { pbWriteVarint(w, (3 << 3) | 0); pbWriteVarint(w, assemblyType); }
        if (count != 0)        { pbWriteVarint(w, (4 << 3) | 0); pbWriteVarint(w, count); }
        // itemIDs = repeated individual varints (not packed)
        if (itemIDsArr != null) {
            for (hexID in itemIDsArr) {
                pbWriteVarint(w, (5 << 3) | 0);
                pbWriteVarintRaw(w, FS.unhex8(Std.string(hexID)));
            }
        }
        if (fieldName != null && fieldName != "") pbWriteLenDelim(w, 6, Bytes.ofString(fieldName));
        return w.get();
    }

    // ── Protobuf encoding primitives ──────────────────────────────────────────

    static function pbWriteVarint(w : BinWriter, v : Int) : Void {
        // Write tag+value as varint sequence
        pbWriteVarintRaw(w, v);
    }

    static function pbWriteVarintRaw(w : BinWriter, v : Int) : Void {
        var b = new BinWriter();
        var uv = v; // treat as unsigned bit pattern
        while (true) {
            var chunk = uv & 0x7F;
            uv = uv >>> 7;
            if (uv != 0) {
                var out = Bytes.alloc(1); out.set(0, chunk | 0x80);
                w.writeBytes(out);
            } else {
                var out = Bytes.alloc(1); out.set(0, chunk);
                w.writeBytes(out);
                break;
            }
        }
    }

    static function pbWriteLenDelim(w : BinWriter, fieldNo : Int, data : Bytes) : Void {
        // Write: (fieldNo << 3 | 2) as varint, then length as varint, then bytes
        pbWriteVarintRaw(w, (fieldNo << 3) | 2);
        pbWriteVarintRaw(w, data.length);
        w.writeBytes(data);
    }

    /** Read a float field from a Dynamic JSON object */
    static function fF(o : Dynamic, k : String) : Float {
        var v = Reflect.field(o, k);
        if (v == null) return 0.0;
        if (Std.isOfType(v, Float)) return cast(v, Float);
        if (Std.isOfType(v, Int)) return cast(v, Int) * 1.0;
        return Std.parseFloat(Std.string(v));
    }

    /**
     * Re-encode a JSON file as compact UTF-8 bytes (for script.json and similar).
     * JSON-only metadata — no raw backup needed.
     */
    static function compactJsonBytes(d : String, name : String) : Null<Bytes> {
        var p = FS.join(d, name);
        if (!FS.exists(p)) return null;
        var obj = FS.readJson(p);
        return Bytes.ofString(haxe.Json.stringify(obj));
    }

    /**
     * Read meta: prefer meta_raw.bin (exact original bytes written by C#),
     * fall back to re-encoding the named JSON file compactly.
     */
    static function readMetaRaw(d : String, jsonName : String) : Null<Bytes> {
        var rawPath = FS.join(d, "meta_raw.bin");
        if (FS.exists(rawPath)) return FS.readBytes(rawPath);
        return compactJsonBytes(d, jsonName);
    }

    /** Read a file as raw Bytes, return null if not present */
    static function tryRead(d : String, name : String) : Null<Bytes> {
        var p = FS.join(d, name);
        return FS.exists(p) ? FS.readBytes(p) : null;
    }

    // ── JSON field helpers ────────────────────────────────────────────────────

    static function iF(o : Dynamic, k : String) : Int {
        var v = Reflect.field(o, k); return v == null ? 0 : Std.int(v);
    }
    static function sF(o : Dynamic, k : String) : String {
        var v = Reflect.field(o, k); return v == null ? "" : Std.string(v);
    }
    static function bF(o : Dynamic, k : String) : Bool {
        var v = Reflect.field(o, k);
        if (v == null) return false;
        if (Std.isOfType(v, Bool)) return cast(v, Bool);
        return v != 0;
    }

    static function die(msg : String) : Void { Sys.println('[ERROR] $msg'); Sys.exit(1); }
}

typedef NodeRec2 = { resType: Int, referenceID: Int, name: String, children: Array<NodeRec2> }
