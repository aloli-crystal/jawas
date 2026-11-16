module Jawas::Sources
  # SQLite 3 : chaque chemin de `paths` est une « base ».
  #
  # `format = "backup"` (défaut) utilise l'API de sauvegarde en ligne
  # (`.backup`) : copie binaire cohérente, même pendant des écritures.
  # `format = "sql"` produit un dump SQL texte (`.dump`).
  class SQLite < Source
    def initialize(config : Config::SourceConfig, @work_dir : String)
      super(config)
    end

    def binaries : Array(String)
      [binary]
    end

    # Le nom d'une base est le nom du fichier sans son extension.
    def databases : Array(String)
      names = super.map { |path| db_name(path) }
      if dup = names.find { |other| names.count(other) > 1 }
        raise ConfigError.new("source #{name} : deux fichiers donnent le même nom de base « #{dup} »")
      end
      names
    end

    def discover : Array(String)
      @config.databases
    end

    def extension(db : String) : String
      sql? ? ".sql" : ".sqlite3"
    end

    def dump(db : String, output : IO) : Nil
      path = path_for(db)
      raise DumpError.new("fichier SQLite introuvable : #{path}") unless File.file?(path)
      if sql?
        run!(binary, ["-bail", path, ".dump"], output)
      else
        Dir.mkdir_p(@work_dir, 0o700)
        tmp = File.tempname("jawas-#{db}-", ".sqlite3", dir: @work_dir)
        begin
          raise DumpError.new("chemin de travail invalide (apostrophe) : #{tmp}") if tmp.includes?('\'')
          run!(binary, ["-bail", path, ".backup '#{tmp}'"], IO::Memory.new)
          File.open(tmp) { |file| IO.copy(file, output) }
        ensure
          File.delete?(tmp)
        end
      end
    end

    # Fichier voisin de l'original : `<base>.r<AAAAMMJJHHMM>.sqlite3`.
    def default_target(db : String, time : Time) : String
      File.join(File.dirname(path_for(db)), "#{Layout.safe(db)}.r#{time.to_s("%Y%m%d%H%M")}.sqlite3")
    end

    # La cible est un chemin de fichier.
    def validate_target(target : String) : Nil
      return if Dir.exists?(File.dirname(File.expand_path(target)))
      raise UsageError.new("répertoire de la cible introuvable : #{File.dirname(target)}")
    end

    def target_exists?(target : String) : Bool
      File.exists?(target)
    end

    # Rien à créer : le fichier est remplacé d'un bloc par `restore_from`.
    def prepare_target(target : String, replace : Bool) : Nil
      validate_target(target)
    end

    def drop_target(target : String) : Nil
    end

    # Écrit la base dans un fichier temporaire voisin, vérifie
    # `PRAGMA integrity_check`, puis le renomme sur la cible (atomique :
    # la cible n'est jamais à moitié écrite).
    def restore_from(target : String, format : String, input : IO) : Nil
      validate_target(target)
      tmp = File.tempname(".jawas-restore-", ".sqlite3", dir: File.dirname(File.expand_path(target)))
      begin
        if format == ".sql"
          feed!(binary, ["-bail", tmp]) { |sink| IO.copy(input, sink) }
        else
          File.open(tmp, "w", perm: 0o600) { |file| IO.copy(input, file) }
        end
        verdict = capture!(binary, [tmp, "PRAGMA integrity_check"]).strip
        raise DumpError.new("integrity_check : #{verdict.lines.first?}") unless verdict == "ok"
        File.rename(tmp, target)
      ensure
        File.delete?(tmp)
      end
    end

    def db_name(path : String) : String
      File.basename(path).sub(/\.(sqlite3?|db3?)\z/, "")
    end

    private def path_for(db : String) : String
      @config.databases.find { |path| db_name(path) == db } || raise DumpError.new("base SQLite inconnue : #{db}")
    end

    private def sql? : Bool
      case format = @config.format
      when nil, "backup" then false
      when "sql"         then true
      else                    raise ConfigError.new("source #{name} : format « #{format} » inconnu (backup, sql)")
      end
    end

    @binary : String?

    private def binary : String
      @binary ||= find_binary(@config.dump_bin, %w[sqlite3])
    end
  end
end
