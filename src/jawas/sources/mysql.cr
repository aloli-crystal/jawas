module Jawas::Sources
  # MySQL et MariaDB, via `mysqldump` / `mariadb-dump`.
  #
  # Les identifiants sont écrits dans un fichier d'options temporaire
  # (mode 0600) passé en `--defaults-extra-file` ; si la source déclare
  # `defaults_file`, ce fichier est utilisé tel quel.
  class MySQL < Source
    @options_file : String?

    def initialize(config : Config::SourceConfig, @work_dir : String)
      super(config)
    end

    def binaries : Array(String)
      [dump_binary, client_binary]
    end

    def extension(db : String) : String
      ".sql"
    end

    def discover : Array(String)
      capture!(client_binary, connection_args + ["--batch", "--skip-column-names", "-e", "SHOW DATABASES"])
        .lines.map(&.strip).reject(&.empty?)
    end

    def dump(db : String, output : IO) : Nil
      run!(dump_binary, dump_args(db), output)
    end

    def dump_args(db : String) : Array(String)
      args = connection_args
      args << "--single-transaction" << "--quick" if @config.single_transaction?
      args << "--routines" if @config.routines?
      args << "--events" if @config.events?
      args << "--triggers" << "--hex-blob" << "--default-character-set=utf8mb4"
      @config.exclude_tables.each do |entry|
        table_db, _, table = entry.partition('.')
        args << "--ignore-table=#{db}.#{table}" if table_db == db && !table.empty?
      end
      args.concat(@config.extra_args)
      args << "--databases" << db
    end

    def close : Nil
      if file = @options_file
        File.delete?(file)
        @options_file = nil
      end
    end

    # `--defaults-extra-file` doit être le premier argument.
    private def connection_args : Array(String)
      ["--defaults-extra-file=#{options_file}"]
    end

    private def options_file : String
      if existing = @config.defaults_file
        return existing
      end
      @options_file ||= write_options_file
    end

    private def write_options_file : String
      Dir.mkdir_p(@work_dir, 0o700)
      file = File.tempfile("jawas-#{@config.name}-", ".cnf", dir: @work_dir)
      File.chmod(file.path, 0o600)
      file.puts "[client]"
      {"host" => @config.host, "port" => @config.port.try(&.to_s), "socket" => @config.socket,
       "user" => @config.user, "password" => @config.password}.each do |key, value|
        file.puts %(#{key}="#{escape(value)}") if value
      end
      file.close
      file.path
    end

    private def escape(value : String) : String
      value.gsub('\\', "\\\\").gsub('"', "\\\"")
    end

    private def dump_binary : String
      @dump_binary ||= find_binary(@config.dump_bin, mariadb? ? %w[mariadb-dump mysqldump] : %w[mysqldump mariadb-dump])
    end

    private def client_binary : String
      @client_binary ||= find_binary(@config.client_bin, mariadb? ? %w[mariadb mysql] : %w[mysql mariadb])
    end

    @dump_binary : String?
    @client_binary : String?

    private def mariadb? : Bool
      @config.engine == "mariadb"
    end
  end
end
