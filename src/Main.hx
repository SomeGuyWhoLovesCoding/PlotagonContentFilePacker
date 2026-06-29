package;

class Main {
    static function main() {
        var args = Sys.args();
        if (args.length < 3) {
            printUsage();
            Sys.exit(1);
        }
        switch (args[0].toLowerCase()) {
            case "unpack": Unpacker.run(args[1], args[2]);
            case "pack":   Packer.run(args[1], args[2]);
            default:
                Sys.println('Unknown command: ${args[0]}');
                printUsage();
                Sys.exit(1);
        }
    }

    static function printUsage() {
        Sys.println("PCF Tool");
        Sys.println("  pcf_tool unpack <input.pcf>    <output_folder>");
        Sys.println("  pcf_tool pack   <input_folder> <output.pcf>");
    }
}
