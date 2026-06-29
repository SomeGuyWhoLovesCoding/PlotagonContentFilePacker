package;

/**
 * PCFResourceType constants and name<->value conversion.
 *
 * Values above 0x8000000 (ANIMATIONCLIP) may overflow signed Int32 on
 * some Haxe targets, so they are handled carefully via the maps below.
 * We store them as raw Int (two's-complement) — the same bit pattern
 * the C# code writes — and display them as unsigned hex strings.
 */
class RT {
    public static inline var NONE               : Int = 0;
    public static inline var OBJECT             : Int = 1;
    public static inline var ROOT               : Int = 2;
    public static inline var NODE               : Int = 4;
    public static inline var INDEX              : Int = 8;
    public static inline var SCRIPT             : Int = 0x10;
    public static inline var MESH               : Int = 0x20;
    public static inline var SKINNEDMESH        : Int = 0x40;
    public static inline var TRANSFORM          : Int = 0x80;
    public static inline var ANIMATOR           : Int = 0x100;
    public static inline var AVATARREFERENCE    : Int = 0x200;
    public static inline var ANIMATION          : Int = 0x400;
    public static inline var MATERIAL           : Int = 0x800;
    public static inline var MATERIALPOINTER    : Int = 0x1000;
    public static inline var TRANSFORMPOINTER   : Int = 0x2000;
    public static inline var TEXTURE            : Int = 0x4000;
    public static inline var LIGHT              : Int = 0x8000;
    public static inline var LIGHTPROBES        : Int = 0x10000;
    public static inline var INTERNALBUNDLE     : Int = 0x20000;
    public static inline var CAMERA             : Int = 0x40000;
    public static inline var COLLIDER           : Int = 0x80000;
    public static inline var AUDIO              : Int = 0x100000;
    public static inline var WEIGHTS            : Int = 0x200000;
    public static inline var PRIMITIVE          : Int = 0x400000;
    public static inline var COLLECTION         : Int = 0x800000;
    public static inline var POINTERCOLLECTION  : Int = 0x1000000;
    public static inline var CLASS              : Int = 0x2000000;
    public static inline var GRADIENT           : Int = 0x4000000;
    public static inline var ANIMATIONCLIP      : Int = 0x8000000;
    // These three exceed the positive Int32 range on 32-bit targets:
    public static inline var ANIMATIONCLIPREFERENCE : Int = 0x10000000;
    public static inline var ANIMATIONLOADER        : Int = 0x20000000;
    public static inline var GRIDCLUSTER            : Int = 0x40000000;

    static var _n2v : Null<Map<String,Int>> = null;
    static var _v2n : Null<Map<Int,String>> = null;

    static function init() {
        if (_n2v != null) return;
        var pairs : Array<{n:String, v:Int}> = [
            {n:"NONE",               v:NONE},
            {n:"OBJECT",             v:OBJECT},
            {n:"ROOT",               v:ROOT},
            {n:"NODE",               v:NODE},
            {n:"INDEX",              v:INDEX},
            {n:"SCRIPT",             v:SCRIPT},
            {n:"MESH",               v:MESH},
            {n:"SKINNEDMESH",        v:SKINNEDMESH},
            {n:"TRANSFORM",          v:TRANSFORM},
            {n:"ANIMATOR",           v:ANIMATOR},
            {n:"AVATARREFERENCE",    v:AVATARREFERENCE},
            {n:"ANIMATION",          v:ANIMATION},
            {n:"MATERIAL",           v:MATERIAL},
            {n:"MATERIALPOINTER",    v:MATERIALPOINTER},
            {n:"TRANSFORMPOINTER",   v:TRANSFORMPOINTER},
            {n:"TEXTURE",            v:TEXTURE},
            {n:"LIGHT",              v:LIGHT},
            {n:"LIGHTPROBES",        v:LIGHTPROBES},
            {n:"INTERNALBUNDLE",     v:INTERNALBUNDLE},
            {n:"CAMERA",             v:CAMERA},
            {n:"COLLIDER",           v:COLLIDER},
            {n:"AUDIO",              v:AUDIO},
            {n:"WEIGHTS",            v:WEIGHTS},
            {n:"PRIMITIVE",          v:PRIMITIVE},
            {n:"COLLECTION",         v:COLLECTION},
            {n:"POINTERCOLLECTION",  v:POINTERCOLLECTION},
            {n:"CLASS",              v:CLASS},
            {n:"GRADIENT",           v:GRADIENT},
            {n:"ANIMATIONCLIP",      v:ANIMATIONCLIP},
            {n:"ANIMATIONCLIPREFERENCE", v:ANIMATIONCLIPREFERENCE},
            {n:"ANIMATIONLOADER",    v:ANIMATIONLOADER},
            {n:"GRIDCLUSTER",        v:GRIDCLUSTER},
        ];
        _n2v = new Map();
        _v2n = new Map();
        for (p in pairs) { _n2v[p.n] = p.v; _v2n[p.v] = p.n; }
    }

    public static function toName(v : Int) : String {
        init();
        var n = _v2n[v];
        if (n != null) return n;
        return "UNKNOWN_" + StringTools.hex(v, 8);
    }

    public static function fromName(s : String) : Int {
        init();
        var v = _n2v[s];
        if (v != null) return v;
        if (StringTools.startsWith(s, "UNKNOWN_"))
            return Std.parseInt("0x" + s.substr(8));
        throw 'Unknown resource type: $s';
    }
}
