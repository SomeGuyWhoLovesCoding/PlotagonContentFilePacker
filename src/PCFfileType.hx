package;
class PCFfileType {
    public static function name(v : Int) : String {
        return switch (v) {
            case 0: "None";
            case 1: "Actor";
            case 2: "Scene";
            case 3: "CCItem";
            case 4: "Avatar";
            case 5: "Music";
            case 6: "SoundEffect";
            case 7: "Animation";
            default: "Unknown_" + v;
        };
    }
}
