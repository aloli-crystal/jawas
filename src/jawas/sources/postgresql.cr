module Jawas::Sources
  # PostgreSQL, via `pg_dump` (une base) et `pg_dumpall --globals-only`
  # (rôles et tablespaces, sauvegardés sous le nom `_globals`).
  #
  # `format = "plain"` (défaut) produit du SQL ; `format = "custom"`
  # produit une archive `pg_restore` non compressée (`-Z 0`), la
  # compression restant celle de `[compression]`.
  class PostgreSQL < Source
    GLOBALS = "_globals"

    def binaries : Array(String)
      list = [dump_binary, client_binary]
      list << dumpall_binary if @config.globals?
      list
    end

    def extension(db : String) : String
      db != GLOBALS && custom? ? ".pgdump" : ".sql"
    end

    def databases : Array(String)
      list = super
      list.unshift(GLOBALS) if @config.globals? && !list.includes?(GLOBALS)
      list
    end

    def discover : Array(String)
      sql = "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1"
      capture!(client_binary, connection_args + ["-X", "-A", "-t", "-d", "postgres", "-c", sql], env)
        .lines.map(&.strip).reject(&.empty?)
    end

    def dump(db : String, output : IO) : Nil
      if db == GLOBALS
        run!(dumpall_binary, connection_args + ["--globals-only"], output, env)
      else
        run!(dump_binary, dump_args(db), output, env)
      end
    end

    def dump_args(db : String) : Array(String)
      args = connection_args
      args.concat(custom? ? ["-F", "c", "-Z", "0"] : ["-F", "p"])
      @config.exclude_tables.each do |entry|
        table_db, _, table = entry.partition('.')
        args << "--exclude-table=#{table}" if table_db == db && !table.empty?
      end
      args.concat(@config.extra_args)
      args << "--dbname=#{db}"
    end

    def target_exists?(target : String) : Bool
      validate_target(target)
      query("SELECT 1 FROM pg_database WHERE datname = '#{target}'").strip == "1"
    end

    def prepare_target(target : String, replace : Bool) : Nil
      validate_target(target)
      query(%(DROP DATABASE IF EXISTS "#{target}")) if replace
      query(%(CREATE DATABASE "#{target}"))
    end

    def drop_target(target : String) : Nil
      validate_target(target)
      query(%(DROP DATABASE IF EXISTS "#{target}"))
    end

    # SQL : `psql` arrêté à la première erreur ; format custom :
    # `pg_restore --exit-on-error` lu sur l'entrée standard.
    def restore_from(target : String, format : String, input : IO) : Nil
      validate_target(target)
      if format == ".pgdump"
        feed!(restore_binary, connection_args + ["--exit-on-error", "--dbname=#{target}"], env) do |sink|
          IO.copy(input, sink)
        end
      else
        args = connection_args + ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", target]
        feed!(client_binary, args, env) { |sink| IO.copy(input, sink) }
      end
    end

    private def query(sql : String) : String
      capture!(client_binary, connection_args + ["-X", "-A", "-t", "-d", "postgres", "-c", sql], env)
    end

    @restore_binary : String?

    private def restore_binary : String
      @restore_binary ||= sibling("pg_restore")
    end

    # `-w` : jamais d'invite de mot de passe (exécution sous cron).
    private def connection_args : Array(String)
      args = ["-w"]
      if host = (@config.socket || @config.host)
        args << "-h" << host
      end
      if port = @config.port
        args << "-p" << port.to_s
      end
      if user = @config.user
        args << "-U" << user
      end
      args
    end

    private def env : Process::Env
      result = {} of String => String?
      if password = @config.password
        result["PGPASSWORD"] = password
      end
      if file = @config.defaults_file
        result["PGPASSFILE"] = file
      end
      result
    end

    private def custom? : Bool
      case format = @config.format
      when nil, "plain" then false
      when "custom"     then true
      else                   raise ConfigError.new("source #{name} : format « #{format} » inconnu (plain, custom)")
      end
    end

    @dump_binary : String?
    @dumpall_binary : String?
    @client_binary : String?

    private def dump_binary : String
      @dump_binary ||= find_binary(@config.dump_bin, %w[pg_dump])
    end

    private def dumpall_binary : String
      @dumpall_binary ||= sibling("pg_dumpall")
    end

    private def client_binary : String
      @client_binary ||= find_binary(@config.client_bin, %w[psql])
    end

    # Si `dump_bin` pointe vers une version précise de PostgreSQL, on
    # prend `pg_dumpall` dans le même répertoire.
    private def sibling(tool : String) : String
      if configured = @config.dump_bin
        candidate = File.join(File.dirname(dump_binary), tool)
        return candidate if configured.includes?('/') && File::Info.executable?(candidate)
      end
      find_binary(nil, [tool])
    end
  end
end
