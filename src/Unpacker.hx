package;

import haxe.io.Bytes;
import sys.io.File;

/**
 * Deep unpacker — each resource type gets its own structured subfolder layout
 * based on exactly what each C# node Deserialize() method reads.
 */
class Unpacker {

    public static function run(pcfPath : String, outDir : String) : Void {
        Sys.println('Unpacking: $pcfPath  →  $outDir');
        if (!FS.exists(pcfPath)) die('Input not found: $pcfPath');

        var raw = File.getBytes(pcfPath);
        Sys.println('  File size: ${raw.length} bytes');

        var r = new BinReader(raw);
        var version    = r.readI32();
        var fileLength = r.readI32();
        var fileType   = r.readI32();

        FS.mkdirs(outDir);
        writeHeader(outDir, version, fileLength, fileType);

        var nodeRoot  : Null<NodeRec> = null;
        var resBlocks : Array<ResBlock> = [];

        while (!r.eof()) {
            if (r.remaining() < 8) break;
            var cl = r.readI32();
            if (cl < 4) break;
            if (cl > r.remaining()) { Sys.println('[WARN] chunkLen overflow, stopping'); break; }
            var bt = r.readI32();
            var pl = cl - 4;
            if (bt == PCFBlockTypes.INDEX) {
                r.skip(pl);
            } else if (bt == PCFBlockTypes.NODE) {
                nodeRoot = parseNodeBlock(r.readBytes(pl));
            } else if (bt == PCFBlockTypes.RESOURCE) {
                if (pl < 8) { r.skip(pl); continue; }
                var rtRaw = r.readI32();
                resBlocks.push(parseResBlock(rtRaw, r.readBytes(pl - 4)));
            } else {
                Sys.println('[WARN] Unknown blockType=$bt, skipping $pl bytes');
                r.skip(pl);
            }
        }

        if (nodeRoot != null) {
            var nd = FS.join(outDir, "nodes");
            FS.mkdir(nd);
            FS.writeJson(FS.join(nd, "node_tree.json"), nodeRecToJson(nodeRoot));
            Sys.println('  Node tree written.');
        } else {
            Sys.println('  [WARN] No node block found.');
        }

        Sys.println('  Writing ${resBlocks.length} resource block(s)...');
        var resRoot = FS.join(outDir, "resources");
        FS.mkdir(resRoot);
        for (rb in resBlocks) writeResBlock(resRoot, rb);

        Sys.println('Done.');
    }

    // ── Header ────────────────────────────────────────────────────────────────

    static function writeHeader(outDir : String, version : Int, fileLength : Int, fileType : Int) : Void {
        var o : Dynamic = {};
        Reflect.setField(o, "version",      version);
        Reflect.setField(o, "fileLength",   fileLength);
        Reflect.setField(o, "fileType",     fileType);
        Reflect.setField(o, "fileTypeName", PCFfileType.name(fileType));
        FS.writeJson(FS.join(outDir, "header.json"), o);
    }

    // ── Node block ────────────────────────────────────────────────────────────

    static function parseNodeBlock(bytes : Bytes) : Null<NodeRec> {
        if (bytes.length == 0) return null;
        return readNodeRec(new BinReader(bytes));
    }

    static function readNodeRec(r : BinReader) : Null<NodeRec> {
        if (r.remaining() < 16) return null;
        var cc = r.readI32();
        var rt = r.readI32();
        var ri = r.readI32();
        var nl = r.readI32();
        var nm = nl > 0 ? r.readUtf8(nl) : "";
        var ch : Array<NodeRec> = [];
        for (_ in 0...cc) { var c = readNodeRec(r); if (c != null) ch.push(c); }
        return { resType: rt, referenceID: ri, name: nm, children: ch };
    }

    static function nodeRecToJson(n : NodeRec) : Dynamic {
        var o : Dynamic = {};
        Reflect.setField(o, "resourceType",      RT.toName(n.resType));
        Reflect.setField(o, "resourceTypeValue", n.resType);
        Reflect.setField(o, "referenceID",       FS.hex8(n.referenceID));
        Reflect.setField(o, "name",              n.name);
        var kids : Array<Dynamic> = [];
        for (c in n.children) kids.push(nodeRecToJson(c));
        Reflect.setField(o, "children", kids);
        return o;
    }

    // ── Resource block ────────────────────────────────────────────────────────

    static function parseResBlock(rt : Int, bytes : Bytes) : ResBlock {
        var r   = new BinReader(bytes);
        var cnt = r.readI32();
        var assets : Array<AssetRec> = [];
        for (i in 0...cnt) {
            if (r.remaining() < 4) break;
            var al = r.readI32();
            if (al <= 0 || al > r.remaining()) break;
            var rem = al;
            var rid = r.readI32(); rem -= 4;
            var str = r.readBool(); rem -= 1;
            var mdt = r.readI32(); rem -= 4;
            var mdl = r.readI32(); rem -= 4;
            var meta : Null<Bytes> = null;
            if (mdl > 0 && mdl <= rem) { meta = r.readBytes(mdl); rem -= mdl; }
            var data : Null<Bytes> = null;
            if (rem > 0) data = r.readBytes(rem);
            assets.push({ resourceID: rid, streamed: str, metaDataType: mdt, meta: meta, data: data });
        }
        return { resTypeRaw: rt, assets: assets };
    }

    // ── Write resource block ───────────────────────────────────────────────────

    static function writeResBlock(resRoot : String, rb : ResBlock) : Void {
        var typeName = RT.toName(rb.resTypeRaw);
        var typeDir  = FS.join(resRoot, typeName);
        FS.mkdir(typeDir);
        var bi : Dynamic = {};
        Reflect.setField(bi, "resourceType",      typeName);
        Reflect.setField(bi, "resourceTypeValue", rb.resTypeRaw);
        Reflect.setField(bi, "assetCount",        rb.assets.length);
        FS.writeJson(FS.join(typeDir, "block_info.json"), bi);
        for (i in 0...rb.assets.length)
            writeAsset(typeDir, rb.assets[i], rb.resTypeRaw, i);
    }

    static function writeAsset(typeDir : String, a : AssetRec, rt : Int, order : Int) : Void {
        var idHex    = FS.hex8(a.resourceID);
        var assetDir = FS.join(typeDir, idHex);
        FS.mkdir(assetDir);

        var ai : Dynamic = {};
        Reflect.setField(ai, "resourceID",       idHex);
        Reflect.setField(ai, "order",            order);
        Reflect.setField(ai, "streamed",         a.streamed);
        Reflect.setField(ai, "metaDataType",     a.metaDataType);
        Reflect.setField(ai, "metaDataTypeName", MetaDataType.name(a.metaDataType));
        FS.writeJson(FS.join(assetDir, "asset_info.json"), ai);

        // ── SCRIPT ─────────────────────────────────────────────────────────
        // meta = JSON { "scriptname": "..." }   |  no data
        // JSON is the editable source — no raw bin needed (meta is trivially re-encodable)
        if (rt == RT.SCRIPT) {
            if (a.meta != null) FS.writeJson(FS.join(assetDir, "script.json"), parseJsonMeta(a.meta));

        // ── TRANSFORM ──────────────────────────────────────────────────────
        } else if (rt == RT.TRANSFORM) {
            if (a.data != null && a.data.length >= 36) {
                var tf : Dynamic = {};
                Reflect.setField(tf, "position", vec3bits(a.data, 0)); // floats 0,1,2
                Reflect.setField(tf, "rotation", vec3bits(a.data, 3)); // floats 3,4,5
                Reflect.setField(tf, "scale",    vec3bits(a.data, 6)); // floats 6,7,8
                FS.writeJson(FS.join(assetDir, "transform.json"), tf);
            }

        // ── CAMERA ─────────────────────────────────────────────────────────
        // no meta  |  data = 6 × float32 LE: bgColor{r,g,b,a} fieldOfView aspect
        // camera.json stores human-readable floats + _bits for exact round-trip.
        // Edit the float values freely; delete a _bits field to use your edited value.
        } else if (rt == RT.CAMERA) {
            if (a.data != null && a.data.length >= 24) {
                var cam : Dynamic = {};
                Reflect.setField(cam, "bgColor",      rgba_bits(a.data, 0));
                Reflect.setField(cam, "fieldOfView",   floatField(a.data, 4));
                Reflect.setField(cam, "aspect",        floatField(a.data, 5));
                FS.writeJson(FS.join(assetDir, "camera.json"), cam);
            }

        // ── LIGHT ──────────────────────────────────────────────────────────
        // no meta  |  data = 6 × float32 LE: color{r,g,b,a} lightType(int-as-float) intensity
        // light.json stores human-readable floats + _bits for exact round-trip.
        } else if (rt == RT.LIGHT) {
            if (a.data != null && a.data.length >= 24) {
                var lt : Dynamic = {};
                Reflect.setField(lt, "color",     rgba_bits(a.data, 0));
                Reflect.setField(lt, "lightType",  Std.int(readFloats(a.data, 5)[4]));
                Reflect.setField(lt, "intensity",  floatField(a.data, 5));
                FS.writeJson(FS.join(assetDir, "light.json"), lt);
            }

        // ── LIGHTPROBES ────────────────────────────────────────────────────
        // meta = JSON { "numberOfProbes": N }
        // data = N × 120 bytes, interleaved per probe:
        //   3 × float32  position (world space xyz)
        //   27 × float32 SphericalHarmonicsL2 coefficients (9 per R, G, B channel)
        //                Layout: [r0..r8, g0..g8, b0..b8]
        // The LightProbes Unity object itself lives in the INTERNALBUNDLE children
        // (baked LightingDataContainer). This data.bin is the raw serialized form
        // of the same probe positions/coefficients used by that object.
        } else if (rt == RT.LIGHTPROBES) {
            if (a.meta != null) writeJsonMeta(assetDir, "lightprobes_meta.json", a.meta);
            if (a.data != null && a.data.length > 0) {
                FS.writeBytes(FS.join(assetDir, "data.bin"), a.data);
                // Deep decode: emit one entry per probe with position + SH coefficients
                var nProbes = Std.int(a.data.length / 120);
                if (nProbes * 120 == a.data.length) {
                    var probes : Array<Dynamic> = [];
                    for (i in 0...nProbes) {
                        var base = i * 120;
                        var f = readFloats(a.data.sub(base, 120), 30);
                        var pos : Dynamic = {};
                        Reflect.setField(pos, "x", roundF(f[0]));
                        Reflect.setField(pos, "y", roundF(f[1]));
                        Reflect.setField(pos, "z", roundF(f[2]));
                        // SH: 27 coefficients in layout [r0..r8, g0..g8, b0..b8]
                        var sh : Dynamic = {};
                        var rArr : Array<Float> = [for (j in 0...9) roundF(f[3+j])];
                        var gArr : Array<Float> = [for (j in 0...9) roundF(f[12+j])];
                        var bArr : Array<Float> = [for (j in 0...9) roundF(f[21+j])];
                        Reflect.setField(sh, "r", rArr);
                        Reflect.setField(sh, "g", gArr);
                        Reflect.setField(sh, "b", bArr);
                        var probe : Dynamic = {};
                        Reflect.setField(probe, "index",    i);
                        Reflect.setField(probe, "position", pos);
                        Reflect.setField(probe, "sh",       sh);
                        probes.push(probe);
                    }
                    var lp : Dynamic = {};
                    Reflect.setField(lp, "numberOfProbes", nProbes);
                    Reflect.setField(lp, "probes", probes);
                    FS.writeJson(FS.join(assetDir, "lightprobes_probes.json"), lp);
                }
            }

        // ── COLLIDER ───────────────────────────────────────────────────────
        // No meta, no data. The engine adds a BoxCollider with default parameters.
        // The TRANSFORM node on the same OBJECT controls the collider's position,
        // rotation, and scale (since BoxCollider inherits the GameObject's transform).
        // asset_info.json presence is the only thing needed — no other files.
        } else if (rt == RT.COLLIDER) {
            // intentionally empty — see TRANSFORM sibling for size/position

        // ── MESH ───────────────────────────────────────────────────────────
        // meta = JSON { "materialID": uint32 }
        // data = MeshBakingUtilities binary:
        //   uint16 vertexCount, uint16 triCount, uint8 flags
        //   WriteVector3Array16bit(vertices)  — bounds(6×f32) + verts×3×uint16
        //   WriteVector3ArrayBytes(normals)   — verts×3 bytes (signed byte: v*127+128)
        //   WriteVector4ArrayBytes(tangents)  — verts×4 bytes
        //   WriteVector2Array16bit(uvs)       — bounds(4×f32) + verts×2×uint16
        //   uint16[] triangles                — triCount×3 × uint16
        //   uint16 blendShapeCount [+ blend shape data]
        //   WriteVector3Array16bit([bounds.center, bounds.size])
        //   [uint16 colorCount; Color32[] colors]
        } else if (rt == RT.MESH) {
            if (a.meta != null) writeJsonMeta(assetDir, "mesh_meta.json", a.meta);
            if (a.data != null && a.data.length > 0) {
                FS.writeBytes(FS.join(assetDir, "mesh_data.bin"), a.data);
                var metaObj = a.meta != null ? parseJsonMeta(a.meta) : null;
                var matID   = metaObj != null ? Reflect.field(metaObj, "materialID") : null;
                extractMesh(assetDir, a.data, false, matID);
            }

        // ── SKINNEDMESH ────────────────────────────────────────────────────
        // Same binary format but header has extra uint16 bindposeCount,
        // followed by Matrix4x4[] bindposes and BoneWeight[] boneWeights.
        // The skinnedmesh meta JSON carries rig info (bones, rootBone, etc.)
        } else if (rt == RT.SKINNEDMESH) {
            if (a.meta != null) {
                writeJsonMeta(assetDir, "skinnedmesh_meta.json", a.meta);
                // Emit a rig summary for quick reference
                var metaObj  = parseJsonMeta(a.meta);
                var bones    : Array<Dynamic> = Reflect.field(metaObj, "bones");
                var bsw      : Array<Dynamic> = Reflect.field(metaObj, "blendShapeWeights");
                var matID    = Reflect.field(metaObj, "materialID");
                var summary  : Dynamic = {};
                Reflect.setField(summary, "materialID",        matID != null ? FS.hex8(Std.int(matID)) : null);
                Reflect.setField(summary, "rootBone",          Reflect.field(metaObj, "rootBone"));
                Reflect.setField(summary, "probeAnchor",       Reflect.field(metaObj, "probeAnchor"));
                Reflect.setField(summary, "quality",           Reflect.field(metaObj, "quality"));
                Reflect.setField(summary, "boneCount",         bones != null ? bones.length : 0);
                Reflect.setField(summary, "bones",             bones);
                Reflect.setField(summary, "blendShapeCount",   bsw   != null ? bsw.length   : 0);
                Reflect.setField(summary, "blendShapeWeights", bsw);
                FS.writeJson(FS.join(assetDir, "skinnedmesh_summary.json"), summary);
            }
            if (a.data != null && a.data.length > 0) {
                FS.writeBytes(FS.join(assetDir, "mesh_data.bin"), a.data);
                var metaObj2 = a.meta != null ? parseJsonMeta(a.meta) : null;
                var matID2   = metaObj2 != null ? Reflect.field(metaObj2, "materialID") : null;
                var bonesArr : Array<Dynamic> = metaObj2 != null ? Reflect.field(metaObj2, "bones") : null;
                extractMesh(assetDir, a.data, true, matID2, bonesArr);
            }

        // ── TEXTURE ────────────────────────────────────────────────────────
        // meta = JSON { "width", "height", "textureFormat"(1=PVRTC,2=RGB32,3=RGB24,4=ASTC6x6), "fieldName" }
        // data = raw pixel/compressed bytes
        } else if (rt == RT.TEXTURE) {
            if (a.meta != null) {
                // Inject textureFormatName into the decoded JSON for readability.
                // meta_raw.bin still preserves the original bytes for lossless round-trip.
                var metaObj = parseJsonMeta(a.meta);
                var fmt : Int = 0;
                var fmtRaw = Reflect.field(metaObj, "textureFormat");
                if (fmtRaw != null) fmt = Std.int(fmtRaw);
                Reflect.setField(metaObj, "textureFormatName", textureFormatName(fmt));
                FS.writeJson(FS.join(assetDir, "texture_meta.json"), metaObj);
                // Raw bytes for packer — must not include textureFormatName
                FS.writeBytes(FS.join(assetDir, "meta_raw.bin"), a.meta);
            }
            if (a.data != null && a.data.length > 0) FS.writeBytes(FS.join(assetDir, "texture_data.bin"), a.data);

        // ── AUDIO ──────────────────────────────────────────────────────────
        // meta = JSON { "fieldName", "name", "arrayItem", "samples", "sampleRate", "streamed" }
        // data = raw audio bytes (cached as .ogg by engine)
        } else if (rt == RT.AUDIO) {
            if (a.meta != null) writeJsonMeta(assetDir, "audio_meta.json", a.meta);
            if (a.data != null && a.data.length > 0) FS.writeBytes(FS.join(assetDir, "audio_data.bin"), a.data);

        // ── MATERIAL ───────────────────────────────────────────────────────
        // meta = protobuf SerializedMaterial:
        //   field1=DisplayName(str) field2=MaterialName submsg field3=ShaderName submsg
        //   field4=repeated map entries {field1=propName(str), field2=property submsg}
        //     PropertyType varint: 2=Float, 3=Color, 4=Texture, 5=Vector
        //     Color (field200 submsg): field1=R,field2=G,field3=B,field4=A (f32)
        //     Texture (field400 submsg): field1=ReferenceID (varint)
        // ── MATERIAL ───────────────────────────────────────────────────────
        // meta = protobuf SerializedMaterial  |  no data
        //
        // material_data.json is the single editable+encodable source.
        // It contains every field needed to reconstruct the exact binary:
        //   displayName, materialName{cg,gles}, shaderName{cg,gles},
        //   properties[]{name, type, typeName, referenceID/value/color/vector}
        //
        // material_meta.bin is kept alongside as a byte-exact fallback.
        // The packer prefers material_meta.bin for round-trip safety;
        // delete it to make the packer encode from material_data.json instead.
        } else if (rt == RT.MATERIAL) {
            if (a.meta != null) {
                FS.writeBytes(FS.join(assetDir, "material_meta.bin"), a.meta);
                var info = decodeMaterial(a.meta);
                if (info != null) FS.writeJson(FS.join(assetDir, "material_data.json"), info);
            }

        // ── MATERIALPOINTER ────────────────────────────────────────────────
        // no meta  |  data = uint32 target material referenceID
        } else if (rt == RT.MATERIALPOINTER) {
            if (a.data != null && a.data.length >= 4) {
                var ptr : Dynamic = {};
                Reflect.setField(ptr, "targetMaterialID", FS.hex8(a.data.getInt32(0)));
                FS.writeJson(FS.join(assetDir, "pointer.json"), ptr);
            }
            if (a.data != null) FS.writeBytes(FS.join(assetDir, "pointer_raw.bin"), a.data);

        // ── TRANSFORMPOINTER ───────────────────────────────────────────────
        // meta = JSON { "fieldName" }  |  data = uint32 target referenceID
        } else if (rt == RT.TRANSFORMPOINTER) {
            if (a.meta != null) writeJsonMeta(assetDir, "transformpointer_meta.json", a.meta);
            if (a.data != null && a.data.length >= 4) {
                var ptr : Dynamic = {};
                Reflect.setField(ptr, "targetReferenceID", FS.hex8(a.data.getInt32(0)));
                FS.writeJson(FS.join(assetDir, "pointer.json"), ptr);
            }
            if (a.data != null) FS.writeBytes(FS.join(assetDir, "pointer_raw.bin"), a.data);

        // ── INTERNALBUNDLE ─────────────────────────────────────────────────
        // meta = JSON { "platform": "standalone"|"ios"|"android", "contents": "" }
        // data = raw Unity AssetBundle (magic "UnityFS\0" for Unity 5.x+)
        //
        // The engine matches bundle platform to the runtime platform and loads
        // the matching one. The bundle contains a LightingDataContainer
        // GameObject whose LightProbe component holds the baked light probe
        // data for the scene. The three platform variants encode the same
        // probe data compiled for different GPU/compression targets.
        //
        // Extraction: in addition to bundle_data.bin we write a platform-named
        // .unity3d file so the bundle can be opened directly in AssetStudio,
        // uTinyRipper, or dragged into a Unity project.
        } else if (rt == RT.INTERNALBUNDLE) {
            if (a.meta != null) writeJsonMeta(assetDir, "bundle_meta.json", a.meta);
            if (a.data != null && a.data.length > 0) {
                FS.writeBytes(FS.join(assetDir, "bundle_data.bin"), a.data);
                // Write the platform-named .unity3d alias
                var platform = "unknown";
                try {
                    var mj = parseJsonMeta(a.meta);
                    var p = Reflect.field(mj, "platform");
                    if (p != null) platform = Std.string(p);
                } catch (_) {}
                FS.writeBytes(FS.join(assetDir, 'bundle_$platform.unity3d'), a.data);
            }

        // ── ANIMATOR ───────────────────────────────────────────────────────
        // meta = JSON { "applyRootMotion": bool, "avatarReferenceID": uint32 }  |  no data
        } else if (rt == RT.ANIMATOR) {
            if (a.meta != null) writeJsonMeta(assetDir, "animator.json", a.meta);

        // ── AVATARREFERENCE ────────────────────────────────────────────────
        // meta = JSON { "avatarName": "..." }  |  no data
        } else if (rt == RT.AVATARREFERENCE) {
            if (a.meta != null) writeJsonMeta(assetDir, "avatar.json", a.meta);
            if (a.data != null && a.data.length > 0) FS.writeBytes(FS.join(assetDir, "data.bin"), a.data);

        // ── PRIMITIVE ──────────────────────────────────────────────────────
        // meta = protobuf SerializedFieldData  |  data = raw typed value bytes
        // primitive_decoded.json is the editable source (field name, type, value).
        // primitive_meta.bin + primitive_data.bin kept as fallback for unknown types.
        } else if (rt == RT.PRIMITIVE) {
            if (a.meta != null) FS.writeBytes(FS.join(assetDir, "primitive_meta.bin"), a.meta);
            if (a.data != null && a.data.length > 0) FS.writeBytes(FS.join(assetDir, "primitive_data.bin"), a.data);
            if (a.meta != null) {
                var decoded = decodePrimitive(a.meta, a.data);
                if (decoded != null) FS.writeJson(FS.join(assetDir, "primitive_decoded.json"), decoded);
            }

        // ── COLLECTION ─────────────────────────────────────────────────────
        // meta = protobuf SerializedCollectionData:
        //   field1=type(int) field2=typeName(str) field3=assemblyType(int)
        //   field4=arrayItem(bool) field5=itemIDs(packed bytes, absent if empty)
        //   field6=fieldName(str)
        // collection_info.json is the editable source
        } else if (rt == RT.COLLECTION) {
            if (a.meta != null) {
                var info = decodeSerializedCollectionData(a.meta);
                FS.writeJson(FS.join(assetDir, "collection_info.json"), info);
            }

        // ── POINTERCOLLECTION ──────────────────────────────────────────────
        // Same protobuf structure as COLLECTION
        } else if (rt == RT.POINTERCOLLECTION) {
            if (a.meta != null) {
                var info = decodeSerializedCollectionData(a.meta);
                FS.writeJson(FS.join(assetDir, "collection_info.json"), info);
            }

        // ── CLASS ──────────────────────────────────────────────────────────
        // meta = protobuf SerializedFieldData:
        //   field1=type(int) field2=typeName(str) field3=assemblyType(int)
        //   field4=arrayItem(bool) field5=fieldName(str)
        // class_info.json is the editable source
        } else if (rt == RT.CLASS) {
            if (a.meta != null) {
                var info = decodeSerializedFieldData(a.meta);
                FS.writeJson(FS.join(assetDir, "class_info.json"), info);
            }

        // ── GRADIENT ───────────────────────────────────────────────────────
        // meta = protobuf SerializedFieldData (same structure as CLASS)
        // gradient_info.json is the editable source
        } else if (rt == RT.GRADIENT) {
            if (a.meta != null) {
                var info = decodeSerializedFieldData(a.meta);
                FS.writeJson(FS.join(assetDir, "gradient_info.json"), info);
            }

        // ── GRIDCLUSTER ────────────────────────────────────────────────────
        // meta = protobuf SerializedFieldData (same structure as CLASS)
        // data = raw protobuf GridUnit bytes (opaque — kept as gridcluster_data.bin)
        // gridcluster_info.json is the editable meta source
        } else if (rt == RT.GRIDCLUSTER) {
            if (a.meta != null) {
                var info = decodeSerializedFieldData(a.meta);
                FS.writeJson(FS.join(assetDir, "gridcluster_info.json"), info);
            }
            if (a.data != null && a.data.length > 0) FS.writeBytes(FS.join(assetDir, "gridcluster_data.bin"), a.data);

        // ── WEIGHTS ────────────────────────────────────────────────────────
        // meta = JSON { "type", "arrayItem", "fieldName", "weightCount" }
        // data = weightCount × (int32_LE length + WeightTable protobuf)
        // WeightTable fields (from AOTSerializer):
        //   f1=BoneName0, f2=BoneName1, f3=BoneName2, f4=BoneName3 (strings)
        //   f5=Weight0, f6=Weight1, f7=Weight2, f8=Weight3 (Fixed32, omitted if 0)
        // weights_decoded.json is the editable source; weights_data.bin kept as fallback
        } else if (rt == RT.WEIGHTS) {
            if (a.meta != null) writeJsonMeta(assetDir, "weights_meta.json", a.meta);
            if (a.data != null && a.data.length > 0) {
                FS.writeBytes(FS.join(assetDir, "weights_data.bin"), a.data);
                var decoded = decodeWeights(a.data);
                if (decoded != null) FS.writeJson(FS.join(assetDir, "weights_decoded.json"), decoded);
            }

        // ── ANIMATION ──────────────────────────────────────────────────────
        } else if (rt == RT.ANIMATION) {
            if (a.meta != null) {
                if (a.metaDataType == MetaDataType.JSON)
                    writeJsonMeta(assetDir, "animation_meta.json", a.meta);
                else
                    FS.writeBytes(FS.join(assetDir, "animation_meta.bin"), a.meta);
            }
            if (a.data != null && a.data.length > 0) FS.writeBytes(FS.join(assetDir, "animation_data.bin"), a.data);

        // ── ANIMATIONCLIP ──────────────────────────────────────────────────
        // meta = JSON { "name", "frameRate", "wrapMode", "fieldName" }
        // data = protobuf SerializedAnimationClip:
        //   field1=PostWrapMode(int) field2=PreWrapMode(int)
        //   field3=repeated AnimationChannel entry:
        //     field1=channelName(int, SerializedAnimationChannelName enum)
        //     field2=repeated keyframe:
        //       field1=Time(f32) field2=Value(f32) field3=InTangent(f32) field4=OutTangent(f32)
        // clip_decoded.json is the editable source for keyframe data
        } else if (rt == RT.ANIMATIONCLIP) {
            if (a.meta != null) writeJsonMeta(assetDir, "clip_meta.json", a.meta);
            if (a.data != null && a.data.length > 0) {
                FS.writeBytes(FS.join(assetDir, "clip_data.bin"), a.data);
                var clipDecoded = decodeAnimationClip(a.data);
                if (clipDecoded != null) FS.writeJson(FS.join(assetDir, "clip_decoded.json"), clipDecoded);
            }

        // ── ANIMATIONCLIPREFERENCE ─────────────────────────────────────────
        // meta = JSON { "fieldName" }  |  data = uint32 pointed node referenceID
        } else if (rt == RT.ANIMATIONCLIPREFERENCE) {
            if (a.meta != null) writeJsonMeta(assetDir, "clipref_meta.json", a.meta);
            if (a.data != null && a.data.length >= 4) {
                var ptr : Dynamic = {};
                Reflect.setField(ptr, "pointedNodeID", FS.hex8(a.data.getInt32(0)));
                FS.writeJson(FS.join(assetDir, "pointer.json"), ptr);
            }
            if (a.data != null) FS.writeBytes(FS.join(assetDir, "pointer_raw.bin"), a.data);

        // ── ANIMATIONLOADER ────────────────────────────────────────────────
        } else if (rt == RT.ANIMATIONLOADER) {
            if (a.meta != null) FS.writeBytes(FS.join(assetDir, "animloader_meta.bin"), a.meta);
            if (a.data != null && a.data.length > 0) FS.writeBytes(FS.join(assetDir, "animloader_data.bin"), a.data);

        // ── Generic fallback ───────────────────────────────────────────────
        } else {
            if (a.meta != null && a.meta.length > 0)
                FS.writeBytes(FS.join(assetDir, 'meta.${MetaDataType.ext(a.metaDataType)}'), a.meta);
            if (a.data != null && a.data.length > 0)
                FS.writeBytes(FS.join(assetDir, "data.bin"), a.data);
        }
    }

    // ── Binary helpers ────────────────────────────────────────────────────────

    /** vec3 with exact bits. off = first float index in the flat array (0, 3, or 6). */
    static function vec3bits(b : Bytes, off : Int) : Dynamic {
        var v : Dynamic = {};
        var i0 = (off+0)*4; var i1 = (off+1)*4; var i2 = (off+2)*4;
        Reflect.setField(v, "x",      haxe.io.FPHelper.i32ToFloat(b.getInt32(i0)));
        Reflect.setField(v, "y",      haxe.io.FPHelper.i32ToFloat(b.getInt32(i1)));
        Reflect.setField(v, "z",      haxe.io.FPHelper.i32ToFloat(b.getInt32(i2)));
        Reflect.setField(v, "x_bits", FS.hex8(b.getInt32(i0)));
        Reflect.setField(v, "y_bits", FS.hex8(b.getInt32(i1)));
        Reflect.setField(v, "z_bits", FS.hex8(b.getInt32(i2)));
        return v;
    }

    /** rgba with exact bits. off = first float index (always 0 for bgColor/color). */
    static function rgba_bits(b : Bytes, off : Int) : Dynamic {
        var v : Dynamic = {};
        var i0 = (off+0)*4; var i1 = (off+1)*4; var i2 = (off+2)*4; var i3 = (off+3)*4;
        Reflect.setField(v, "r",      haxe.io.FPHelper.i32ToFloat(b.getInt32(i0)));
        Reflect.setField(v, "g",      haxe.io.FPHelper.i32ToFloat(b.getInt32(i1)));
        Reflect.setField(v, "b",      haxe.io.FPHelper.i32ToFloat(b.getInt32(i2)));
        Reflect.setField(v, "a",      haxe.io.FPHelper.i32ToFloat(b.getInt32(i3)));
        Reflect.setField(v, "r_bits", FS.hex8(b.getInt32(i0)));
        Reflect.setField(v, "g_bits", FS.hex8(b.getInt32(i1)));
        Reflect.setField(v, "b_bits", FS.hex8(b.getInt32(i2)));
        Reflect.setField(v, "a_bits", FS.hex8(b.getInt32(i3)));
        return v;
    }

    /** Single float field at float index idx, with exact bits. */
    static function floatField(b : Bytes, idx : Int) : Dynamic {
        var bits = b.getInt32(idx * 4);
        var v : Dynamic = {};
        Reflect.setField(v, "value", haxe.io.FPHelper.i32ToFloat(bits));
        Reflect.setField(v, "bits",  FS.hex8(bits));
        return v;
    }

    static function readFloats(b : Bytes, n : Int) : Array<Float> {
        var result = [];
        for (i in 0...n) result.push(haxe.io.FPHelper.i32ToFloat(b.getInt32(i * 4)));
        return result;
    }

    static function vec3(f : Array<Float>, o : Int) : Dynamic {
        var v : Dynamic = {};
        Reflect.setField(v, "x", roundF(f[o]));
        Reflect.setField(v, "y", roundF(f[o+1]));
        Reflect.setField(v, "z", roundF(f[o+2]));
        return v;
    }

    static function rgba(f : Array<Float>, o : Int) : Dynamic {
        var v : Dynamic = {};
        Reflect.setField(v, "r", roundF(f[o]));
        Reflect.setField(v, "g", roundF(f[o+1]));
        Reflect.setField(v, "b", roundF(f[o+2]));
        Reflect.setField(v, "a", roundF(f[o+3]));
        return v;
    }

    /** Round float to 6 significant digits to avoid floating-point noise in JSON */
    static function roundF(f : Float) : Float {
        if (f == 0.0 || Math.isNaN(f)) return f;
        var abs = f < 0 ? -f : f;
        if (abs > 1e30) return f; // effectively infinite
        var factor = Math.pow(10, 6 - Math.floor(Math.log(abs) / Math.log(10)) - 1);
        return Math.round(f * factor) / factor;
    }

    /**
     * Write meta bytes as both a pretty-printed JSON file (for editing)
     * and a raw binary file (for lossless round-trip).
     * The packer always reads meta_raw.bin; the .json is for humans.
     */
    static function writeJsonMeta(assetDir : String, jsonName : String, meta : Bytes) : Void {
        FS.writeJson(FS.join(assetDir, jsonName), parseJsonMeta(meta));
        FS.writeBytes(FS.join(assetDir, "meta_raw.bin"), meta);
    }

    // ── Mesh extraction ───────────────────────────────────────────────────────

    /**
     * Decode MeshBakingUtilities binary and emit:
     *   mesh_info.json  — vertex/tri counts, bounds, blend shape names, flags
     *   mesh.obj        — Wavefront OBJ with positions, normals, UVs
     *   [mesh_skinning.json]  — bind poses + per-vertex bone weights (skinned only)
     */
    static function extractMesh(assetDir : String, data : Bytes, readSkinning : Bool,
                                 matID : Dynamic, ?boneNames : Array<Dynamic>) : Void {
        var r = new BinReader(data);

        // ── Header ────────────────────────────────────────────────────────
        var vc   = readU16(r);       // vertex count
        var tc   = readU16(r);       // triangle count (number of triangles, not indices)
        var bpc  = readSkinning ? readU16(r) : 0;  // bindpose count
        var flags = r.readBytes(1).get(0);
        var hasNormals  = (flags & 2) != 0;
        var hasTangents = (flags & 4) != 0;
        var hasUV       = (flags & 8) != 0;

        // ── Vertices (16-bit quantized, always present) ───────────────────
        var vMinX = readF32(r); var vMaxX = readF32(r);
        var vMinY = readF32(r); var vMaxY = readF32(r);
        var vMinZ = readF32(r); var vMaxZ = readF32(r);
        var rawV  = r.readBytes(vc * 3 * 2);
        var verts : Array<Array<Float>> = [];
        for (i in 0...vc) {
            var ux = getU16(rawV, i*6+0);
            var uy = getU16(rawV, i*6+2);
            var uz = getU16(rawV, i*6+4);
            verts.push([
                ux / 65535.0 * (vMaxX - vMinX) + vMinX,
                uy / 65535.0 * (vMaxY - vMinY) + vMinY,
                uz / 65535.0 * (vMaxZ - vMinZ) + vMinZ
            ]);
        }

        // ── Normals (byte quantized, always present in ReadMesh) ──────────
        var rawN = r.readBytes(vc * 3);
        var normals : Array<Array<Float>> = [];
        for (i in 0...vc) {
            normals.push([
                (rawN.get(i*3+0) - 128) / 127.0,
                (rawN.get(i*3+1) - 128) / 127.0,
                (rawN.get(i*3+2) - 128) / 127.0
            ]);
        }

        // ── Tangents (byte quantized, always consumed in ReadMesh) ────────
        r.skip(vc * 4);  // consumed but we don't export to OBJ

        // ── UVs (16-bit quantized) ─────────────────────────────────────────
        var uMinU = readF32(r); var uMaxU = readF32(r);
        var uMinV = readF32(r); var uMaxV = readF32(r);
        var rawUV = r.readBytes(vc * 2 * 2);
        var uvs : Array<Array<Float>> = [];
        for (i in 0...vc) {
            var uu = getU16(rawUV, i*4+0);
            var uv = getU16(rawUV, i*4+2);
            uvs.push([
                uu / 65535.0 * (uMaxU - uMinU) + uMinU,
                uv / 65535.0 * (uMaxV - uMinV) + uMinV
            ]);
        }

        // ── Skinning data ─────────────────────────────────────────────────
        var bindposes  : Array<Array<Float>> = [];
        var boneWts    : Array<Array<Float>> = [];
        var boneIdxs   : Array<Array<Int>>   = [];
        if (readSkinning) {
            for (_ in 0...bpc) {
                var mat : Array<Float> = [];
                for (_ in 0...16) mat.push(readF32(r));
                bindposes.push(mat);
            }
            for (_ in 0...vc) {
                var w0=readF32(r); var w1=readF32(r); var w2=readF32(r); var w3=readF32(r);
                var bi0=readU16(r); var bi1=readU16(r); var bi2=readU16(r); var bi3=readU16(r);
                boneWts.push([w0,w1,w2,w3]);
                boneIdxs.push([bi0,bi1,bi2,bi3]);
            }
        }

        // ── Indices ────────────────────────────────────────────────────────
        var rawIdx = r.readBytes(tc * 3 * 2);
        var indices : Array<Int> = [];
        for (i in 0...tc*3) indices.push(getU16(rawIdx, i*2));

        // ── Blend shapes ───────────────────────────────────────────────────
        var bsc = readU16(r);
        var blendShapeNames : Array<String> = [];
        for (_ in 0...bsc) {
            var nameLen = readU16(r);
            var name    = r.readUtf8(nameLen);
            blendShapeNames.push(name);
            // delta verts: bounds(6×f32) + vc×3×uint16
            r.skip(6*4 + vc*3*2);
            // delta normals + delta tangents: vc×3 bytes each
            r.skip(vc*3 + vc*3);
        }

        // ── Bounds (2 fake verts) ──────────────────────────────────────────
        r.skip(6*4 + 2*3*2);  // bounds header + 2 quantized verts

        // ── Colors (optional) ──────────────────────────────────────────────
        var hasColors = false;
        var colorCount = 0;
        if (r.remaining() >= 2) {
            colorCount = readU16(r);
            if (colorCount > 0) { r.skip(colorCount * 4); hasColors = true; }
        }

        // ── Write mesh_info.json ───────────────────────────────────────────
        var info : Dynamic = {};
        Reflect.setField(info, "vertexCount",     vc);
        Reflect.setField(info, "triangleCount",   tc);
        Reflect.setField(info, "hasNormals",      hasNormals);
        Reflect.setField(info, "hasTangents",     hasTangents);
        Reflect.setField(info, "hasUV",           hasUV);
        Reflect.setField(info, "hasColors",       hasColors);
        Reflect.setField(info, "blendShapeCount", bsc);
        if (bsc > 0) Reflect.setField(info, "blendShapeNames", blendShapeNames);
        if (readSkinning) Reflect.setField(info, "bindposeCount", bpc);
        var matHex = matID != null ? FS.hex8(Std.int(matID)) : null;
        Reflect.setField(info, "materialID", matHex);
        var boundsInfo : Dynamic = {};
        Reflect.setField(boundsInfo, "minX", roundF(vMinX)); Reflect.setField(boundsInfo, "maxX", roundF(vMaxX));
        Reflect.setField(boundsInfo, "minY", roundF(vMinY)); Reflect.setField(boundsInfo, "maxY", roundF(vMaxY));
        Reflect.setField(boundsInfo, "minZ", roundF(vMinZ)); Reflect.setField(boundsInfo, "maxZ", roundF(vMaxZ));
        Reflect.setField(info, "bounds", boundsInfo);
        FS.writeJson(FS.join(assetDir, "mesh_info.json"), info);

        // ── Write mesh.obj ────────────────────────────────────────────────
        // Unity is left-handed (+Z forward). Right-handed viewers (Blender,
        // Microsoft 3D Viewer) expect +Z forward right-handed, which requires
        // negating X and reversing face winding so normals stay correct.
        var obj = new StringBuf();
        obj.add('# PCF Mesh Export\n');
        obj.add('# vertexCount=$vc  triCount=$tc\n');
        if (matHex != null) obj.add('# materialID=$matHex\n');
        obj.add('\n');
        for (v in verts) obj.add('v ${f6(-v[0])} ${f6(v[1])} ${f6(v[2])}\n');
        obj.add('\n');
        for (n in normals) obj.add('vn ${f6(-n[0])} ${f6(n[1])} ${f6(n[2])}\n');
        obj.add('\n');
        for (u in uvs) obj.add('vt ${f6(u[0])} ${f6(u[1])}\n');
        obj.add('\n');
        for (i in 0...tc) {
            var a = indices[i*3+0]+1;
            var b = indices[i*3+1]+1;
            var c = indices[i*3+2]+1;
            // Reversed winding (a c b) to compensate for X-flip
            obj.add('f $a/$a/$a $c/$c/$c $b/$b/$b\n');
        }
        FS.writeBytes(FS.join(assetDir, "mesh.obj"), Bytes.ofString(obj.toString()));

        // ── Write mesh_skinning.json (skinned meshes only) ─────────────────
        if (readSkinning && bindposes.length > 0) {
            var sk : Dynamic = {};
            // Bindposes as flat 4×4 row-major arrays
            var bpArr : Array<Dynamic> = [];
            for (i in 0...bindposes.length) {
                var entry : Dynamic = {};
                Reflect.setField(entry, "index",    i);
                Reflect.setField(entry, "boneName", boneNames != null && i < boneNames.length ? Std.string(boneNames[i]) : "bone_" + i);
                Reflect.setField(entry, "matrix",   bindposes[i]);
                bpArr.push(entry);
            }
            Reflect.setField(sk, "bindposes", bpArr);
            // Per-vertex weights (compact: only top-4)
            var wArr : Array<Dynamic> = [];
            for (i in 0...vc) {
                var entry : Dynamic = {};
                Reflect.setField(entry, "v", i);
                Reflect.setField(entry, "weights",  boneWts[i]);
                Reflect.setField(entry, "boneIdx",  boneIdxs[i]);
                wArr.push(entry);
            }
            Reflect.setField(sk, "boneWeights", wArr);
            FS.writeJson(FS.join(assetDir, "mesh_skinning.json"), sk);
        }
    }

    // ── Read helpers for mesh decode ──────────────────────────────────────────

    static inline function readU16(r : BinReader) : Int {
        var b = r.readBytes(2);
        return b.get(0) | (b.get(1) << 8);
    }

    static inline function readF32(r : BinReader) : Float {
        return haxe.io.FPHelper.i32ToFloat(r.readI32());
    }

    static inline function getU16(b : Bytes, off : Int) : Int {
        return b.get(off) | (b.get(off+1) << 8);
    }

    static inline function f6(v : Float) : String {
        // Fixed 6-decimal format for OBJ
        var s = Std.string(Math.round(v * 1000000) / 1000000);
        return s;
    }

    // ── SerializedFieldData / SerializedCollectionData decoders ──────────────
    // Protobuf field mapping (from ProtocolBufferSerializer.cs + PlotagonAOTSerializer):
    //
    // SerializedFieldData:
    //   field 1 = type        (varint, SerializedFieldType)
    //   field 2 = typeName    (string)
    //   field 3 = assemblyType(varint)
    //   field 4 = arrayItem   (varint bool)
    //   field 5 = fieldName   (string)
    //
    // SerializedCollectionData:
    //   field 1 = type        (varint, SerializedFieldType)
    //   field 2 = typeName    (string)
    //   field 3 = assemblyType(varint)
    //   field 4 = count       (varint int)
    //   field 5 = itemIDs     (bytes, packed uint32 varints)
    //   field 6 = fieldName   (string)

    // ── Material decoder ─────────────────────────────────────────────────────

    /**
     * Decode SerializedMaterial protobuf → human-readable material_info.json.
     * Schema (confirmed from real bytes):
     *   field1 = DisplayName (string)
     *   field2 = MaterialName submsg: field1=CGMaterial, field2=GLESMaterial
     *   field3 = ShaderName  submsg: field1=CGShader,  field2=GLESShader
     *   field4 = repeated property map entry:
     *     field1 = propertyName (string)
     *     field2 = SerializedMaterialProperty submsg:
     *       field1  = PropertyType varint (2=Float, 3=Color, 4=Texture, 5=Vector)
     *       field200 = payload submsg (for Color/Float/Vector)
     *       field400 = payload submsg (for Texture)
     * Packer re-encodes from material_info.json; material_meta.bin kept as fallback.
     */
    static function decodeMaterial(b : Bytes) : Null<Dynamic> {
        var fields = scanProtobuf(b);

        var displayName = fields.get(1) != null ? fields.get(1).sv : "";

        // field2 = MaterialName submsg
        var matName : Dynamic = {};
        if (fields.get(2) != null) {
            var sub = scanProtobuf(Bytes.ofString(fields.get(2).sv));
            Reflect.setField(matName, "cg",   sub.get(1) != null ? sub.get(1).sv : "");
            Reflect.setField(matName, "gles", sub.get(2) != null ? sub.get(2).sv : "");
        }

        // field3 = ShaderName submsg
        var shaderName : Dynamic = {};
        if (fields.get(3) != null) {
            var sub = scanProtobuf(Bytes.ofString(fields.get(3).sv));
            Reflect.setField(shaderName, "cg",   sub.get(1) != null ? sub.get(1).sv : "");
            Reflect.setField(shaderName, "gles", sub.get(2) != null ? sub.get(2).sv : "");
        }

        // field4 = repeated property entries — scanProtobuf only returns last value per field
        // so we need a multi-value scan for field4
        var properties : Array<Dynamic> = [];
        var allField4 = scanProtobufMulti(b, 4);
        for (propBytes in allField4) {
            var propFields = scanProtobuf(propBytes);
            var propName = propFields.get(1) != null ? propFields.get(1).sv : "";
            var propValBytes = propFields.get(2) != null ? Bytes.ofString(propFields.get(2).sv) : null;

            var entry : Dynamic = {};
            Reflect.setField(entry, "name", propName);

            if (propValBytes == null) {
                // Property slot with name only (no value) — preserve as type 0
                Reflect.setField(entry, "type", 0);
                Reflect.setField(entry, "typeName", "None");
                properties.push(entry);
                continue;
            }

            var propVal = scanProtobuf(propValBytes);
            // PropertyType enum: FloatType=1, VectorType=2, ColorType=3, TextureType=4
            var propType = propVal.get(1) != null ? propVal.get(1).iv : 0;

            Reflect.setField(entry, "type", propType);
            Reflect.setField(entry, "typeName", switch(propType) {
                case 1: "Float"; case 2: "Vector"; case 3: "Color"; case 4: "Texture"; default: "Unknown_"+propType;
            });

            if (propType == 4) {
                // Texture: field400 submsg → field1 = ReferenceID varint
                var texPayload = propVal.get(400) != null ? Bytes.ofString(propVal.get(400).sv) : null;
                if (texPayload != null) {
                    var texFields = scanProtobuf(texPayload);
                    var refID = texFields.get(1) != null ? texFields.get(1).iv : 0;
                    Reflect.setField(entry, "referenceID", FS.hex8(refID));
                }
            } else if (propType == 1) {
                // Float: field300 submsg → field1 = Val (Fixed32)
                var fPayload = propVal.get(300) != null ? Bytes.ofString(propVal.get(300).sv) : null;
                if (fPayload != null) {
                    var pv = scanProtobufF32(fPayload);
                    Reflect.setField(entry, "value", pv.get(1) != null ? pv.get(1) : 0.0);
                }
            } else if (propType == 3) {
                // Color: field200 submsg → f1=R, f2=G, f3=B, f4=A (Fixed32)
                var payload = propVal.get(200) != null ? Bytes.ofString(propVal.get(200).sv) : null;
                if (payload != null) {
                    var pv = scanProtobufF32(payload);
                    var c : Dynamic = {};
                    Reflect.setField(c, "r", pv.get(1) != null ? pv.get(1) : 0.0);
                    Reflect.setField(c, "g", pv.get(2) != null ? pv.get(2) : 0.0);
                    Reflect.setField(c, "b", pv.get(3) != null ? pv.get(3) : 0.0);
                    Reflect.setField(c, "a", pv.get(4) != null ? pv.get(4) : 0.0);
                    Reflect.setField(entry, "color", c);
                }
            } else if (propType == 2) {
                // Vector: field100 submsg → f1=X, f2=Y, f3=Z, f4=W (Fixed32)
                var payload = propVal.get(100) != null ? Bytes.ofString(propVal.get(100).sv) : null;
                if (payload != null) {
                    var pv = scanProtobufF32(payload);
                    var v2 : Dynamic = {};
                    Reflect.setField(v2, "x", pv.get(1) != null ? pv.get(1) : 0.0);
                    Reflect.setField(v2, "y", pv.get(2) != null ? pv.get(2) : 0.0);
                    Reflect.setField(v2, "z", pv.get(3) != null ? pv.get(3) : 0.0);
                    Reflect.setField(v2, "w", pv.get(4) != null ? pv.get(4) : 0.0);
                    Reflect.setField(entry, "vector", v2);
                }
            }
            properties.push(entry);
        }

        var o : Dynamic = {};
        Reflect.setField(o, "displayName",  displayName);
        Reflect.setField(o, "materialName", matName);
        Reflect.setField(o, "shaderName",   shaderName);
        Reflect.setField(o, "properties",   properties);
        return o;
    }

    // ── AnimationClip decoder ──────────────────────────────────────────────────

    /**
     * Decode SerializedAnimationClip protobuf → clip_decoded.json.
     * Schema:
     *   field1 = PostWrapMode (varint)
     *   field2 = PreWrapMode  (varint)
     *   field3 = repeated AnimationChannel:
     *     field1 = channelName (varint, SerializedAnimationChannelName enum)
     *     field2 = repeated SerializedAnimationKeyFrame:
     *   field 1 = repeated AnimationChannels map entry (KVP subitem):
     *               f1 = channelName (varint, SerializedAnimationChannelName)
     *               f2 = repeated keyframe subitems
     *                      f1=Time(f32) f2=Value(f32) f3=InTangent(f32) f4=OutTangent(f32)
     *   field 2 = PostWrapMode (varint)
     *   field 3 = PreWrapMode  (varint)
     * clip_decoded.json is the editable source; clip_data.bin kept as fallback.
     */
    static function decodeAnimationClip(b : Bytes) : Null<Dynamic> {
        // Field 1 = repeated map entries (one per channel)
        var allChannels = scanProtobufMulti(b, 1);

        var topFields = scanProtobuf(b);
        var postWrap = topFields.get(2) != null ? topFields.get(2).iv : 0;
        var preWrap  = topFields.get(3) != null ? topFields.get(3).iv : 0;

        var channels : Array<Dynamic> = [];
        for (chanBytes in allChannels) {
            var cf = scanProtobuf(chanBytes);
            var chanName = cf.get(1) != null ? cf.get(1).iv : 0;

            var keyframes : Array<Dynamic> = [];
            var allKeys = scanProtobufMulti(chanBytes, 2);
            for (kfBytes in allKeys) {
                var kf = scanProtobufF32(kfBytes);
                var kfObj : Dynamic = {};
                Reflect.setField(kfObj, "time",       kf.get(1) != null ? kf.get(1) : 0.0);
                Reflect.setField(kfObj, "value",      kf.get(2) != null ? kf.get(2) : 0.0);
                Reflect.setField(kfObj, "inTangent",  kf.get(3) != null ? kf.get(3) : 0.0);
                Reflect.setField(kfObj, "outTangent", kf.get(4) != null ? kf.get(4) : 0.0);
                keyframes.push(kfObj);
            }

            var chanObj : Dynamic = {};
            Reflect.setField(chanObj, "channelName",    chanName);
            Reflect.setField(chanObj, "channelNameStr", animChannelName(chanName));
            Reflect.setField(chanObj, "keyframes",      keyframes);
            channels.push(chanObj);
        }

        var o : Dynamic = {};
        Reflect.setField(o, "postWrapMode", postWrap);
        Reflect.setField(o, "preWrapMode",  preWrap);
        Reflect.setField(o, "channels",     channels);
        return o;
    }

    static function animChannelName(v : Int) : String {
        // SerializedAnimationChannelName enum: TranslateX=1..ScaleZ=10
        return switch (v) {
            case 1: "TranslateX"; case 2: "TranslateY"; case 3: "TranslateZ";
            case 4: "RotateX";    case 5: "RotateY";    case 6: "RotateZ";    case 7: "RotateW";
            case 8: "ScaleX";     case 9: "ScaleY";     case 10: "ScaleZ";
            default: "Unknown_" + v;
        };
    }

    // ── Extended protobuf scanners ─────────────────────────────────────────────

    /** Collect ALL occurrences of a given field number as raw byte arrays (for repeated fields) */
    static function scanProtobufMulti(b : Bytes, targetField : Int) : Array<Bytes> {
        var result : Array<Bytes> = [];
        var pos = 0;
        while (pos < b.length) {
            var tagResult = readVarint(b, pos); if (tagResult == null) break; pos = tagResult.next;
            var fn = tagResult.v >> 3; var wt = tagResult.v & 7;
            if (wt == 0) {
                var vr = readVarint(b, pos); if (vr == null) break; pos = vr.next;
            } else if (wt == 2) {
                var lr = readVarint(b, pos); if (lr == null) break; pos = lr.next;
                var len = lr.v; if (pos + len > b.length) break;
                if (fn == targetField) result.push(b.sub(pos, len));
                pos += len;
            } else if (wt == 5) { pos += 4; }
            else if (wt == 1) { pos += 8; }
            else break;
        }
        return result;
    }

    /** Scan protobuf returning f32 values keyed by field number (wire type 5) */
    static function scanProtobufF32(b : Bytes) : Map<Int, Float> {
        var m : Map<Int, Float> = new Map();
        var pos = 0;
        while (pos < b.length) {
            var tr = readVarint(b, pos); if (tr == null) break; pos = tr.next;
            var fn = tr.v >> 3; var wt = tr.v & 7;
            if (wt == 5) {
                if (pos + 4 > b.length) break;
                m.set(fn, haxe.io.FPHelper.i32ToFloat(b.getInt32(pos))); pos += 4;
            } else if (wt == 0) {
                var vr = readVarint(b, pos); if (vr == null) break; pos = vr.next;
            } else if (wt == 2) {
                var lr = readVarint(b, pos); if (lr == null) break; pos = lr.next;
                pos += lr.v;
            } else if (wt == 1) { pos += 8; }
            else break;
        }
        return m;
    }

    static function decodeSerializedFieldData(b : Bytes) : Dynamic {
        var fields = scanProtobuf(b);
        var fieldType    = fields.get(1) != null ? fields.get(1).iv : 0;
        var typeName     = fields.get(2) != null ? fields.get(2).sv : "";
        var assemblyType = fields.get(3) != null ? fields.get(3).iv : 0;
        var arrayItem    = fields.get(4) != null ? (fields.get(4).iv != 0) : false;
        var fieldName    = fields.get(5) != null ? fields.get(5).sv : "";
        var o : Dynamic = {};
        Reflect.setField(o, "fieldType",     fieldType);
        Reflect.setField(o, "fieldTypeName", switch(fieldType){case 1:"STRING";case 2:"INT";case 3:"UINT";case 4:"FLOAT";case 5:"DOUBLE";case 6:"BOOLEAN";case 7:"BYTEBUFFER";default:"UNKNOWN";});
        Reflect.setField(o, "typeName",      typeName);
        Reflect.setField(o, "assemblyType",  assemblyType);
        Reflect.setField(o, "assemblyName",  assemblyName(assemblyType));
        Reflect.setField(o, "arrayItem",     arrayItem);
        Reflect.setField(o, "fieldName",     fieldName);
        return o;
    }

    static function decodeSerializedCollectionData(b : Bytes) : Dynamic {
        var fields = scanProtobuf(b);
        var fieldType    = fields.get(1) != null ? fields.get(1).iv : 0;
        var typeName     = fields.get(2) != null ? fields.get(2).sv : "";
        var assemblyType = fields.get(3) != null ? fields.get(3).iv : 0;
        var count        = fields.get(4) != null ? fields.get(4).iv : 0;
        var fieldName    = fields.get(6) != null ? fields.get(6).sv : "";
        // field 5 = itemIDs — written as repeated individual varints (one per item)
        // Use multi-scan to collect all occurrences of field 5
        var itemIDs : Array<String> = [];
        var allF5 = scanProtobufMulti(b, 5);
        for (chunk in allF5) {
            // Each chunk from scanProtobufMulti for a varint field is the raw bytes
            // Actually scanProtobufMulti returns length-delimited payloads.
            // For varint fields we need a different approach: scan the raw bytes directly.
        }
        // Scan raw bytes for all field-5 varints
        var pos = 0;
        while (pos < b.length) {
            // read tag varint
            var tag = 0; var s2 = 0;
            while (pos < b.length) {
                var by = b.get(pos++);
                tag |= (by & 0x7F) << s2; s2 += 7;
                if ((by & 0x80) == 0) break;
            }
            var fn = tag >> 3; var wt = tag & 7;
            if (wt == 0) { // varint
                var v = 0; var sv = 0;
                while (pos < b.length) {
                    var by = b.get(pos++);
                    v |= (by & 0x7F) << sv; sv += 7;
                    if ((by & 0x80) == 0) break;
                }
                if (fn == 5) itemIDs.push(FS.hex8(v));
            } else if (wt == 2) { // length-delimited
                var len2 = 0; var sl = 0;
                while (pos < b.length) {
                    var by = b.get(pos++);
                    len2 |= (by & 0x7F) << sl; sl += 7;
                    if ((by & 0x80) == 0) break;
                }
                pos += len2;
            } else if (wt == 5) { pos += 4; }
            else if (wt == 1) { pos += 8; }
            else break;
        }
        var o : Dynamic = {};
        Reflect.setField(o, "fieldType",     fieldType);
        Reflect.setField(o, "fieldTypeName", switch(fieldType){case 1:"STRING";case 2:"INT";case 3:"UINT";case 4:"FLOAT";case 5:"DOUBLE";case 6:"BOOLEAN";case 7:"BYTEBUFFER";default:"UNKNOWN";});
        Reflect.setField(o, "typeName",      typeName);
        Reflect.setField(o, "assemblyType",  assemblyType);
        Reflect.setField(o, "assemblyName",  assemblyName(assemblyType));
        Reflect.setField(o, "count",         count);
        Reflect.setField(o, "fieldName",     fieldName);
        if (itemIDs.length > 0) Reflect.setField(o, "itemIDs", itemIDs);
        return o;
    }

    static function assemblyName(t : Int) : String {
        return switch (t) {
            case 1: "UnityEngine";
            case 2: "Assembly-CSharp";
            case 3: "mscorlib";
            default: "";
        };
    }

    // ── Weights decoder ───────────────────────────────────────────────────────

    static function decodeWeights(data : Bytes) : Null<Dynamic> {
        var entries : Array<Dynamic> = [];
        var pos = 0;
        while (pos + 4 <= data.length) {
            var entryLen = data.getInt32(pos); pos += 4;
            if (entryLen <= 0 || pos + entryLen > data.length) break;
            var entryBytes = data.sub(pos, entryLen); pos += entryLen;
            var fields = scanProtobuf(entryBytes);
            var entry : Dynamic = {};
            // Bone names: f1-f4
            if (fields.get(1) != null) Reflect.setField(entry, "bone0", fields.get(1).sv);
            if (fields.get(2) != null) Reflect.setField(entry, "bone1", fields.get(2).sv);
            if (fields.get(3) != null) Reflect.setField(entry, "bone2", fields.get(3).sv);
            if (fields.get(4) != null) Reflect.setField(entry, "bone3", fields.get(4).sv);
            // Weights: f5-f8 (Fixed32 — scanProtobuf stores raw bits in .iv)
            // Store both human-readable float AND exact bits for lossless round-trip
            inline function wField(fnum:Int, key:String, bitsKey:String) {
                var f = fields.get(fnum);
                if (f != null) {
                    Reflect.setField(entry, key,     haxe.io.FPHelper.i32ToFloat(f.iv));
                    Reflect.setField(entry, bitsKey, FS.hex8(f.iv));
                }
            }
            wField(5, "w0", "w0_bits"); wField(6, "w1", "w1_bits");
            wField(7, "w2", "w2_bits"); wField(8, "w3", "w3_bits");
            entries.push(entry);
        }
        var o : Dynamic = {};
        Reflect.setField(o, "count",   entries.length);
        Reflect.setField(o, "weights", entries);
        return o;
    }

    static function textureFormatName(fmt : Int) : String {
        return switch (fmt) {
            case 1: "PVRTC4BPP";
            case 2: "RGB32";
            case 3: "RGB24";
            case 4: "ASTC6x6";
            default: "UNKNOWN_" + fmt;
        };
    }

    static function parseJsonMeta(b : Bytes) : Dynamic {
        try { return haxe.Json.parse(b.getString(0, b.length)); }
        catch (_) { var w : Dynamic = {}; Reflect.setField(w, "_raw", b.getString(0, b.length)); return w; }
    }

    // ── Primitive decoder (minimal hand-rolled protobuf scanner) ─────────────

    static function decodePrimitive(metaBytes : Bytes, dataBytes : Null<Bytes>) : Null<Dynamic> {
        var fields = scanProtobuf(metaBytes);
        var fieldType    = fields.get(1) != null ? fields.get(1).iv  : 0;
        var typeName     = fields.get(2) != null ? fields.get(2).sv  : "";
        var assemblyType = fields.get(3) != null ? fields.get(3).iv  : 0;
        var arrayItem    = fields.get(4) != null ? (fields.get(4).iv != 0) : false;
        var fieldName    = fields.get(5) != null ? fields.get(5).sv  : "";

        var valueRep : Dynamic = null;
        if (dataBytes != null && dataBytes.length > 0) {
            valueRep = switch (fieldType) {
                case 1: dataBytes.getString(0, dataBytes.length);
                case 2: dataBytes.getInt32(0);
                case 3: FS.hex8(dataBytes.getInt32(0));
                case 4: haxe.io.FPHelper.i32ToFloat(dataBytes.getInt32(0));
                case 5: haxe.io.FPHelper.i64ToDouble(dataBytes.getInt32(0), dataBytes.getInt32(4));
                case 6: dataBytes.get(0) != 0;
                case 7: dataBytes.toHex();
                default: dataBytes.toHex();
            };
        }

        var o : Dynamic = {};
        Reflect.setField(o, "fieldName",     fieldName);
        Reflect.setField(o, "arrayItem",     arrayItem);
        Reflect.setField(o, "fieldType",     fieldType);
        Reflect.setField(o, "fieldTypeName", switch(fieldType){case 1:"STRING";case 2:"INT";case 3:"UINT";case 4:"FLOAT";case 5:"DOUBLE";case 6:"BOOLEAN";case 7:"BYTEBUFFER";default:"UNKNOWN";});
        Reflect.setField(o, "typeName",      typeName);
        Reflect.setField(o, "assemblyType",  assemblyType);
        Reflect.setField(o, "value",         valueRep);
        return o;
    }

    static function scanProtobuf(b : Bytes) : Map<Int, PBField> {
        var m : Map<Int, PBField> = new Map();
        var p = 0;
        while (p < b.length) {
            var tr = readVarint(b, p); if (tr == null) break; p = tr.next;
            var fn = tr.v >> 3; var wt = tr.v & 7;
            if (wt == 0) {
                var vr = readVarint(b, p); if (vr == null) break; p = vr.next;
                m.set(fn, { iv: vr.v, sv: Std.string(vr.v) });
            } else if (wt == 2) {
                var lr = readVarint(b, p); if (lr == null) break; p = lr.next;
                var len = lr.v; if (p + len > b.length) break;
                m.set(fn, { iv: 0, sv: b.sub(p, len).getString(0, len) });
                p += len;
            } else if (wt == 5) {
                if (p + 4 > b.length) break;
                m.set(fn, { iv: b.getInt32(p), sv: "" }); p += 4;
            } else if (wt == 1) {
                if (p + 8 > b.length) break; p += 8;
            } else break;
        }
        return m;
    }

    static function readVarint(b : Bytes, p : Int) : Null<VR> {
        var r = 0; var s = 0;
        while (p < b.length) {
            var by = b.get(p++);
            r |= (by & 0x7F) << s; s += 7;
            if ((by & 0x80) == 0) return { v: r, next: p };
            if (s >= 35) break;
        }
        return null;
    }

    static function die(msg : String) : Void { Sys.println('[ERROR] $msg'); Sys.exit(1); }
}

typedef NodeRec  = { resType: Int, referenceID: Int, name: String, children: Array<NodeRec> }
typedef AssetRec = { resourceID: Int, streamed: Bool, metaDataType: Int, meta: Null<Bytes>, data: Null<Bytes> }
typedef ResBlock = { resTypeRaw: Int, assets: Array<AssetRec> }
typedef PBField  = { iv: Int, sv: String }
typedef VR       = { v: Int, next: Int }
