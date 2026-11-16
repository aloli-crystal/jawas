require "toml"

module Jawas
  # Configuration TOML de jawas.
  #
  # Recherche (premier fichier trouvé) :
  #
  # 1. `--config CHEMIN` (obligatoirement présent s'il est donné) ;
  # 2. `${XDG_CONFIG_HOME:-~/.config}/jawas/config.toml` (sauf avec
  #    `--no-user-config`) ;
  # 3. `/etc/jawas/config.toml` puis `/usr/local/etc/jawas/config.toml`
  #    (serveurs Linux / FreeBSD).
  #
  # Aucun mot de passe n'est accepté en clair dans ce fichier : voir
  # `password_env`, `password_file` et `defaults_file` dans les sources.
  class Config
    SYSTEM_PATHS = ["/etc/jawas/config.toml", "/usr/local/etc/jawas/config.toml"]
    ENGINES      = %w[mysql mariadb postgresql sqlite]

    record Storage, dir : String, latest : Bool
    record Schedule, weekly_day : Int32, monthly_day : Int32
    record Retention, daily : Int32, weekly : Int32, monthly : Int32, keep_min : Int32 do
      def days_for(period : Period) : Int32
        case period
        in .daily?   then daily
        in .weekly?  then weekly
        in .monthly? then monthly
        end
      end
    end
    record Hooks, pre : Array(String), post : Array(String)

    # Une source = un serveur (ou un lot de fichiers SQLite) à sauvegarder.
    class SourceConfig
      getter name : String
      getter engine : String
      getter host : String?
      getter port : Int32?
      getter socket : String?
      getter user : String?
      getter password_env : String?
      getter password_file : String?
      getter defaults_file : String?
      getter databases : Array(String)
      getter exclude : Array(String)
      getter exclude_tables : Array(String)
      getter extra_args : Array(String)
      getter dump_bin : String?
      getter client_bin : String?
      getter format : String?
      getter? globals : Bool
      getter? single_transaction : Bool
      getter? routines : Bool
      getter? events : Bool

      def initialize(@name, @engine, *, @host = nil, @port = nil, @socket = nil, @user = nil,
                     @password_env = nil, @password_file = nil, @defaults_file = nil,
                     @databases = [] of String, @exclude = [] of String,
                     @exclude_tables = [] of String, @extra_args = [] of String,
                     @dump_bin = nil, @client_bin = nil, @format = nil, @globals = true,
                     @single_transaction = true, @routines = true, @events = true)
      end

      # Mot de passe résolu depuis l'environnement ou un fichier, sans
      # jamais transiter par la ligne de commande.
      def password : String?
        if var = @password_env
          ENV[var]? || raise ConfigError.new("source #{@name} : variable d'environnement #{var} absente")
        elsif file = @password_file
          begin
            File.read(file).chomp
          rescue ex : IO::Error | File::Error
            raise ConfigError.new("source #{@name} : password_file illisible (#{ex.message})")
          end
        end
      end
    end

    getter path : String?
    getter storage : Storage
    getter schedule : Schedule
    getter retention : Retention
    getter compressor : Compressor
    getter encryptor : Encryptor?
    getter hooks : Hooks
    getter sources : Array(SourceConfig)

    def initialize(@storage, @schedule, @retention, @compressor, @hooks, @sources, @path = nil,
                   @encryptor = nil)
      validate!
    end

    def self.locate(explicit : String?, no_user_config : Bool = false) : String
      if explicit
        return explicit if File.file?(explicit)
        raise ConfigError.new("fichier de configuration introuvable : #{explicit}")
      end
      candidates = [] of String
      candidates << File.join(xdg_config_home, "jawas", "config.toml") unless no_user_config
      candidates.concat(SYSTEM_PATHS)
      candidates.find { |candidate| File.file?(candidate) } ||
        raise ConfigError.new("aucune configuration trouvée (essayé : #{candidates.join(", ")}) ; " \
                              "`jawas sample` affiche un modèle")
    end

    def self.xdg_config_home : String
      ENV["XDG_CONFIG_HOME"]?.presence || File.join(Path.home.to_s, ".config")
    end

    def self.load(path : String) : Config
      parse(File.read(path), path)
    rescue ex : File::Error
      raise ConfigError.new("lecture de #{path} impossible : #{ex.message}")
    end

    def self.parse(source : String, path : String? = nil) : Config
      root = Table.new(TOML.parse_to_hash(source), "")
      Builder.new(root, path).build
    rescue ex : TOML::ParseError
      raise ConfigError.new("TOML invalide#{path ? " (#{path})" : ""} : #{ex.message}")
    end

    private def validate!
      raise ConfigError.new("aucune source déclarée ([[source]])") if @sources.empty?
      names = @sources.map(&.name)
      if dup = names.find { |other| names.count(other) > 1 }
        raise ConfigError.new("nom de source en double : #{dup}")
      end
      unless (0..7).includes?(@schedule.weekly_day)
        raise ConfigError.new("schedule.weekly_day doit valoir 0 (désactivé) ou 1 (lundi) … 7 (dimanche)")
      end
      unless (0..31).includes?(@schedule.monthly_day)
        raise ConfigError.new("schedule.monthly_day doit valoir 0 (désactivé) ou 1 … 31")
      end
      {@retention.daily, @retention.weekly, @retention.monthly, @retention.keep_min}.each do |v|
        raise ConfigError.new("les valeurs de [retention] doivent être ≥ 0") if v < 0
      end
    end

    # Accès typé à une table TOML, avec des messages d'erreur qui
    # nomment la clé fautive.
    struct Table
      getter hash : Hash(String, TOML::Type)
      getter prefix : String

      def initialize(@hash, @prefix)
      end

      def key_name(key : String) : String
        @prefix.empty? ? key : "#{@prefix}.#{key}"
      end

      def table(key : String) : Table
        case v = @hash[key]?
        when Nil                      then Table.new({} of String => TOML::Type, key_name(key))
        when Hash(String, TOML::Type) then Table.new(v, key_name(key))
        else                               raise type_error(key, "une table")
        end
      end

      def tables(key : String) : Array(Table)
        case v = @hash[key]?
        when Nil then [] of Table
        when Array(TOML::Type)
          v.map_with_index do |item, i|
            item.is_a?(Hash(String, TOML::Type)) ? Table.new(item, "#{key_name(key)}[#{i}]") : raise type_error(key, "un tableau de tables")
          end
        else raise type_error(key, "un tableau de tables ([[#{key}]])")
        end
      end

      def string?(key : String) : String?
        case v = @hash[key]?
        when Nil    then nil
        when String then v
        else             raise type_error(key, "une chaîne")
        end
      end

      def string(key : String, default : String) : String
        string?(key) || default
      end

      def string!(key : String) : String
        string?(key) || raise ConfigError.new("clé obligatoire manquante : #{key_name(key)}")
      end

      def int?(key : String) : Int32?
        case v = @hash[key]?
        when Nil   then nil
        when Int64 then v.to_i32
        else            raise type_error(key, "un entier")
        end
      end

      def int(key : String, default : Int32) : Int32
        int?(key) || default
      end

      def bool(key : String, default : Bool) : Bool
        case v = @hash[key]?
        when Nil  then default
        when Bool then v
        else           raise type_error(key, "un booléen")
        end
      end

      def strings(key : String, default : Array(String) = [] of String) : Array(String)
        case v = @hash[key]?
        when Nil then default
        when Array(TOML::Type)
          v.map { |item| item.is_a?(String) ? item : raise type_error(key, "un tableau de chaînes") }
        else raise type_error(key, "un tableau de chaînes")
        end
      end

      def unknown_keys(known : Enumerable(String)) : Array(String)
        @hash.keys.reject { |k| known.includes?(k) }.map { |k| key_name(k) }
      end

      private def type_error(key : String, expected : String) : ConfigError
        ConfigError.new("#{key_name(key)} doit être #{expected}")
      end
    end

    # Transforme l'arbre TOML en objets `Config`.
    private struct Builder
      SOURCE_KEYS = %w[name engine host port socket user password_env password_file defaults_file
        databases paths exclude exclude_tables extra_args dump_bin client_bin format globals
        single_transaction routines events]

      def initialize(@root : Table, @path : String?)
      end

      def build : Config
        check_keys(@root, %w[storage schedule retention compression encryption hooks source])
        Config.new(storage, schedule, retention, compressor, hooks, sources, @path, encryptor)
      end

      private def storage : Storage
        t = @root.table("storage")
        check_keys(t, %w[dir latest])
        Storage.new(dir: t.string!("dir"), latest: t.bool("latest", true))
      end

      private def schedule : Schedule
        t = @root.table("schedule")
        check_keys(t, %w[weekly_day monthly_day])
        Schedule.new(weekly_day: t.int("weekly_day", 6), monthly_day: t.int("monthly_day", 1))
      end

      private def retention : Retention
        t = @root.table("retention")
        check_keys(t, %w[daily weekly monthly keep_min])
        Retention.new(daily: t.int("daily", 7), weekly: t.int("weekly", 35),
          monthly: t.int("monthly", 180), keep_min: t.int("keep_min", 2))
      end

      private def compressor : Compressor
        t = @root.table("compression")
        check_keys(t, %w[tool level threads])
        Compressor.new(t.string("tool", "gzip"), t.int?("level"), t.int?("threads"))
      end

      # Section absente : pas de chiffrement. Présente : au moins un
      # destinataire (en ligne ou par fichier).
      private def encryptor : Encryptor?
        return unless @root.hash.has_key?("encryption")
        t = @root.table("encryption")
        check_keys(t, %w[recipients recipients_file binary])
        Encryptor.new(t.strings("recipients"), t.string?("recipients_file"), t.string("binary", "age"))
      end

      private def hooks : Hooks
        t = @root.table("hooks")
        check_keys(t, %w[pre post])
        Hooks.new(pre: t.strings("pre"), post: t.strings("post"))
      end

      private def sources : Array(SourceConfig)
        @root.tables("source").map { |table| source(table) }
      end

      private def source(t : Table) : SourceConfig
        check_keys(t, SOURCE_KEYS)
        engine = t.string!("engine")
        unless ENGINES.includes?(engine)
          raise ConfigError.new("#{t.key_name("engine")} : moteur « #{engine} » inconnu (#{ENGINES.join(", ")})")
        end
        name = t.string!("name")
        unless name.matches?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
          raise ConfigError.new("#{t.key_name("name")} : « #{name} » doit se limiter à [A-Za-z0-9._-]")
        end
        if t.string?("password_env") && t.string?("password_file")
          raise ConfigError.new("source #{name} : password_env et password_file sont exclusifs")
        end
        databases = engine == "sqlite" ? t.strings("paths") : t.strings("databases")
        if engine == "sqlite" && databases.empty?
          raise ConfigError.new("source #{name} : `paths` (fichiers SQLite) est obligatoire")
        end

        SourceConfig.new(name, engine,
          host: t.string?("host"), port: t.int?("port"), socket: t.string?("socket"),
          user: t.string?("user"), password_env: t.string?("password_env"),
          password_file: t.string?("password_file"), defaults_file: t.string?("defaults_file"),
          databases: databases, exclude: t.strings("exclude", default_exclude(engine)),
          exclude_tables: t.strings("exclude_tables"), extra_args: t.strings("extra_args"),
          dump_bin: t.string?("dump_bin"), client_bin: t.string?("client_bin"),
          format: t.string?("format"), globals: t.bool("globals", true),
          single_transaction: t.bool("single_transaction", true),
          routines: t.bool("routines", true), events: t.bool("events", true))
      end

      private def default_exclude(engine : String) : Array(String)
        case engine
        when "mysql", "mariadb" then %w[information_schema performance_schema sys]
        when "postgresql"       then %w[template0 template1]
        else                         [] of String
        end
      end

      private def check_keys(t : Table, known : Array(String)) : Nil
        unknown = t.unknown_keys(known)
        return if unknown.empty?
        raise ConfigError.new("clé(s) inconnue(s) : #{unknown.join(", ")}")
      end
    end
  end
end
