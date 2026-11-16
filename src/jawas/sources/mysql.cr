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

    def target_exists?(target : String) : Bool
      validate_target(target)
      sql = "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '#{target}'"
      !query(sql).strip.empty?
    end

    def prepare_target(target : String, replace : Bool) : Nil
      validate_target(target)
      query("DROP DATABASE IF EXISTS `#{target}`") if replace
      query("CREATE DATABASE `#{target}` CHARACTER SET utf8mb4")
    end

    def drop_target(target : String) : Nil
      validate_target(target)
      query("DROP DATABASE IF EXISTS `#{target}`")
    end

    # Les dumps (`--databases`) commencent par `CREATE DATABASE` et
    # `USE \`base\`` : ces deux lignes d'en-tête sont retirées pour que le
    # chargement aille dans la cible choisie. Le reste passe tel quel.
    def restore_from(target : String, format : String, input : IO) : Nil
      validate_target(target)
      feed!(client_binary, connection_args + ["--database=#{target}"]) do |sink|
        MySQL.strip_database_header(input, sink)
      end
    end

    # Recopie le dump en retirant `CREATE DATABASE` et `USE` de l'en-tête
    # (lignes avant la première table ou donnée) ; le reste est copié
    # en bloc, sans découpage en lignes.
    def self.strip_database_header(input : IO, output : IO) : Nil
      while line = input.gets(chomp: false)
        next if line.starts_with?("CREATE DATABASE ") || line.starts_with?("USE `")
        output << line
        break if line.starts_with?("CREATE TABLE") || line.starts_with?("DROP TABLE") ||
                 line.starts_with?("INSERT ") || line.starts_with?("LOCK TABLES")
      end
      IO.copy(input, output)
    end

    private def query(sql : String) : String
      capture!(client_binary, connection_args + ["--batch", "--skip-column-names", "-e", sql])
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
