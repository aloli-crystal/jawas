module Jawas
  # Compresseur externe appliqué en flux (stdin → stdout) au dump.
  #
  # Outils pris en charge : `none`, `gzip`, `pigz` (gzip parallèle),
  # `bzip2`, `xz`, `zstd`. Le niveau et le nombre de threads sont
  # facultatifs ; sans valeur, l'outil garde son défaut.
  class Compressor
    record Spec, binary : String?, extension : String, levels : Range(Int32, Int32), threads : Bool

    SPECS = {
      "none"  => Spec.new(nil, "", 0..0, false),
      "gzip"  => Spec.new("gzip", ".gz", 1..9, false),
      "pigz"  => Spec.new("pigz", ".gz", 1..9, true),
      "bzip2" => Spec.new("bzip2", ".bz2", 1..9, false),
      "xz"    => Spec.new("xz", ".xz", 0..9, true),
      "zstd"  => Spec.new("zstd", ".zst", 1..19, true),
    }

    getter tool : String
    getter level : Int32?
    getter threads : Int32?

    def initialize(@tool : String = "gzip", @level : Int32? = nil, @threads : Int32? = nil)
      spec = SPECS[@tool]? || raise ConfigError.new(
        "compresseur inconnu « #{@tool} » (#{SPECS.keys.join(", ")})")
      if (lvl = @level) && @tool != "none" && !spec.levels.includes?(lvl)
        raise ConfigError.new("niveau #{lvl} invalide pour #{@tool} (#{spec.levels.begin}…#{spec.levels.end})")
      end
      if (t = @threads) && t < 0
        raise ConfigError.new("threads doit être ≥ 0 (0 = automatique)")
      end
    end

    def none? : Bool
      @tool == "none"
    end

    def binary : String?
      SPECS[@tool].binary
    end

    def extension : String
      SPECS[@tool].extension
    end

    # Arguments de compression (lecture stdin, écriture stdout).
    def compress_args : Array(String)
      args = ["-c"]
      args << "-q" if @tool == "zstd"
      if lvl = @level
        args << "-#{lvl}"
      end
      if (t = @threads) && SPECS[@tool].threads
        args.concat(@tool == "pigz" ? ["-p", t.to_s] : ["-T#{t}"])
      end
      args
    end

    # Arguments de décompression vers stdout.
    def decompress_args : Array(String)
      @tool == "zstd" ? ["-d", "-q", "-c"] : ["-d", "-c"]
    end

    # Arguments du test d'intégrité de l'archive.
    def test_args : Array(String)
      @tool == "zstd" ? ["-t", "-q"] : ["-t"]
    end

    # Retrouve le compresseur d'un fichier d'après son extension.
    def self.for_path(path : String) : Compressor
      tool = case path
             when .ends_with?(".gz")  then "gzip"
             when .ends_with?(".bz2") then "bzip2"
             when .ends_with?(".xz")  then "xz"
             when .ends_with?(".zst") then "zstd"
             else                          "none"
             end
      new(tool)
    end
  end
end
