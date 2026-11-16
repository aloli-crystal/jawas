module Jawas
  # Un moteur de base de données capable de lister ses bases et de
  # produire le dump de l'une d'elles sur un `IO`.
  #
  # Les outils natifs (`mysqldump`, `pg_dump`, `sqlite3`…) sont appelés
  # en sous-processus ; les identifiants ne passent jamais par la ligne
  # de commande (fichier d'options 0600 ou variable d'environnement).
  abstract class Source
    getter config : Config::SourceConfig

    def initialize(@config : Config::SourceConfig)
    end

    def self.for(config : Config::SourceConfig, work_dir : String) : Source
      case config.engine
      when "mysql", "mariadb" then Sources::MySQL.new(config, work_dir)
      when "postgresql"       then Sources::PostgreSQL.new(config)
      when "sqlite"           then Sources::SQLite.new(config, work_dir)
      else                         raise ConfigError.new("moteur inconnu : #{config.engine}")
      end
    end

    def name : String
      @config.name
    end

    # Bases à sauvegarder : la liste explicite si elle est donnée, sinon
    # la découverte auprès du serveur ; les motifs `exclude` (jokers
    # `*` et `?`) sont ensuite retirés.
    def databases : Array(String)
      list = @config.databases.empty? ? discover : @config.databases.dup
      list.reject { |db| @config.exclude.any? { |pattern| File.match?(pattern, db) } }
    end

    # Interroge le serveur pour obtenir la liste de ses bases.
    abstract def discover : Array(String)

    # Écrit le dump de `db` sur `output`. Lève `DumpError` en cas d'échec.
    abstract def dump(db : String, output : IO) : Nil

    # Extension du dump non compressé (`.sql`, `.pgdump`, `.sqlite3`).
    abstract def extension(db : String) : String

    # Exécutables nécessaires (pour `jawas check`).
    abstract def binaries : Array(String)

    # --- Restauration -------------------------------------------------

    # Nom de la base jetable par défaut : `<base>_r<AAAAMMJJHHMM>` de la
    # sauvegarde (SQLite : fichier voisin de l'original).
    def default_target(db : String, time : Time) : String
      stamp = time.to_s("%Y%m%d%H%M")
      "#{Layout.safe(db)[0, 63 - 2 - stamp.size]}_r#{stamp}"
    end

    # Refuse un nom de cible qu'il faudrait échapper.
    def validate_target(target : String) : Nil
      return if target.matches?(/\A[A-Za-z0-9_][A-Za-z0-9_$-]{0,62}\z/)
      raise UsageError.new("nom de base cible invalide : « #{target} » ([A-Za-z0-9_$-], 63 caractères au plus)")
    end

    # La cible existe-t-elle déjà ?
    abstract def target_exists?(target : String) : Bool

    # Crée la cible (après l'avoir supprimée si `replace`).
    abstract def prepare_target(target : String, replace : Bool) : Nil

    # Supprime une cible créée par une restauration qui a échoué.
    abstract def drop_target(target : String) : Nil

    # Charge le dump décodé (`format` : `.sql`, `.pgdump`, `.sqlite3`)
    # dans la cible.
    abstract def restore_from(target : String, format : String, input : IO) : Nil

    # Libère les ressources temporaires (fichier d'options…).
    def close : Nil
    end

    # Résumé de la sortie d'erreur d'un outil : les lignes qui signalent
    # une erreur si elles existent, sinon les dernières lignes.
    def self.error_summary(stderr : String) : String
      lines = stderr.lines.map(&.strip).reject { |line| line.empty? || line.matches?(/\A-+\z/) }
      errors = lines.select(&.matches?(/error|fatal|erreur/i))
      (errors.empty? ? lines.last(3) : errors.last(2)).join(" / ")
    end

    protected def find_binary(configured : String?, candidates : Array(String)) : String
      if configured
        return configured if File::Info.executable?(configured)
        return Process.find_executable(configured) || raise DumpError.new("exécutable introuvable : #{configured}")
      end
      candidates.each do |candidate|
        if found = Process.find_executable(candidate)
          return found
        end
      end
      raise DumpError.new("aucun de ces exécutables n'est dans le PATH : #{candidates.join(", ")}")
    end

    protected def run!(binary : String, args : Array(String), output : IO,
                       env : Process::Env = nil) : Nil
      err = IO::Memory.new
      status = Process.run(binary, args, output: output, error: err, env: env)
      return if status.success?
      message = Source.error_summary(err.to_s)
      raise DumpError.new("#{File.basename(binary)} a échoué (code #{status.exit_code})#{message.empty? ? "" : " : #{message}"}")
    rescue ex : File::Error | IO::Error
      raise DumpError.new("#{File.basename(binary)} : #{ex.message}")
    end

    # Lance `binary` et lui fait lire ce que le bloc écrit. Si le
    # programme s'arrête en route, c'est son propre message d'erreur qui
    # est rapporté, pas le « Broken pipe » de l'écriture.
    protected def feed!(binary : String, args : Array(String), env : Process::Env = nil, & : IO ->) : Nil
      err = IO::Memory.new
      File.open(File::NULL, "w") do |null|
        process = Process.new(binary, args, input: Process::Redirect::Pipe, output: null, error: err, env: env)
        write_error = nil
        begin
          yield process.input
        rescue ex : IO::Error
          write_error = ex
        ensure
          begin
            process.input.close
          rescue IO::Error
          end
        end
        status = process.wait
        unless status.success?
          message = Source.error_summary(err.to_s)
          raise DumpError.new("#{File.basename(binary)} a échoué (code #{status.exit_code})#{message.empty? ? "" : " : #{message}"}")
        end
        raise DumpError.new("#{File.basename(binary)} : #{write_error.message}") if write_error
      end
    end

    protected def capture!(binary : String, args : Array(String), env : Process::Env = nil) : String
      buffer = IO::Memory.new
      run!(binary, args, buffer, env)
      buffer.to_s
    end
  end
end
