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

    # Libère les ressources temporaires (fichier d'options…).
    def close : Nil
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
      message = err.to_s.strip.lines.last(5).join(" / ")
      raise DumpError.new("#{File.basename(binary)} a échoué (code #{status.exit_code})#{message.empty? ? "" : " : #{message}"}")
    rescue ex : File::Error | IO::Error
      raise DumpError.new("#{File.basename(binary)} : #{ex.message}")
    end

    protected def capture!(binary : String, args : Array(String), env : Process::Env = nil) : String
      buffer = IO::Memory.new
      run!(binary, args, buffer, env)
      buffer.to_s
    end
  end
end
