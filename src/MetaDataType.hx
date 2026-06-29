package;
class MetaDataType {
    public static inline var UNKNOWN  : Int = 0;
    public static inline var JSON     : Int = 1;
    public static inline var BINARY   : Int = 2;
    public static inline var PROTOBUF : Int = 3;

    public static function name(v : Int) : String {
        return switch (v) {
            case 1: "JSON";
            case 2: "BINARY";
            case 3: "PROTOBUF";
            default: "UNKNOWN";
        };
    }

    public static function ext(v : Int) : String {
        return switch (v) {
            case 1: "json";
            case 3: "pb";
            default: "bin";
        };
    }
}
