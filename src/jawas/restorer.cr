require "json"

module Jawas
  # Restauration d'une sauvegarde (`jawas restore`).
  #
  # Par défaut la sauvegarde la plus récente de la base est chargée dans
  # une base *jetable* (`<base>_r<AAAAMMJJHHMM>`, ou fichier voisin pour
  # SQLite) : on peut l'inspecter sans rien risquer. Écraser une base
  # existante — l'originale comprise — exige `--into NOM` et `--replace`.
  #
  # L'empreinte SHA-256 est toujours contrôlée avant le chargement ; une
  # base jetable créée pour une restauration qui échoue est supprimée.
  class Restorer
    class Plan
      include JSON::Serializable

      getter source : String
      getter database : String
      getter path : String
      getter target : String
      getter? exists : Bool
      getter? replace : Bool
      getter? original : Bool
      # Remplacement atomique (SQLite : fichier renommé) ; sinon la base
      # est supprimée puis recréée avant le chargement.
      getter? atomic : Bool

      def initialize(@source, @database, @path, @target, @exists, @replace, @original, @atomic)
      end

      def format : String
        File.extname(Decoder.new(@path).plain_name)
      end
    end

    def initialize(@config : Config, @identity : String? = nil, @log : IO = STDERR)
      @layout = Layout.new(@config.storage.dir)
    end

    # Choisit la sauvegarde et la cible. `file` (chemin explicite) prime
    # sur `date` (sauvegarde la plus récente de ce jour), sinon la plus
    # récente tout court.
    def plan(source : String?, database : String?, file : String? = nil, date : Time? = nil,
             into : String? = nil, replace : Bool = false) : Plan
      entry = select_entry(source, database, file, date)
      source_config = source_config(entry.source)
      if Decoder.new(entry.path).encrypted? && @identity.nil?
        raise UsageError.new("sauvegarde chiffrée : --identity (-i) clé privée age requise")
      end
      raise UsageError.new("_globals (rôles PostgreSQL) se rejoue à la main : " \
                           "décoder le fichier puis `psql -d postgres -f -`") if entry.database == Sources::PostgreSQL::GLOBALS
      with_source(source_config) do |engine|
        original = original_target(source_config, engine, entry.database)
        target = into || engine.default_target(entry.database, entry.time)
        engine.validate_target(target)
        exists = engine.target_exists?(target)
        if exists && !replace
          raise UsageError.new("la cible « #{target} » existe déjà : --replace pour l'écraser " \
                               "(sans --into, une base jetable est créée)")
        end
        sqlite = engine.is_a?(Sources::SQLite)
        same = sqlite ? File.expand_path(target) == File.expand_path(original) : target == original
        Plan.new(entry.source, entry.database, entry.path, target, exists, replace, same, sqlite)
      end
    end

    def run(plan : Plan) : Nil
      expected = File.read("#{plan.path}.sha256").split(/\s+/, 2).first rescue nil
      unless expected && expected == Archiver.sha256(plan.path)
        raise DumpError.new("empreinte SHA-256 absente ou différente : restauration refusée (#{plan.path})")
      end
      with_source(source_config(plan.source)) do |engine|
        @log.puts "→ #{plan.exists? ? "remplacement" : "création"} de #{plan.target}"
        engine.prepare_target(plan.target, plan.replace?)
        begin
          @log.puts "→ chargement de #{File.basename(plan.path)}"
          Decoder.new(plan.path, @identity, @config.encryptor.try(&.binary_name) || "age").open do |io|
            engine.restore_from(plan.target, plan.format, io)
          end
        rescue ex : DumpError | IO::Error
          unless plan.exists?
            @log.puts "→ suppression de #{plan.target} (restauration incomplète)"
            engine.drop_target(plan.target) rescue nil
          end
          raise DumpError.new(ex.message)
        end
      end
    end

    private def select_entry(source : String?, database : String?, file : String?, date : Time?) : Inventory::Entry
      if file
        return entry_for_file(file, source)
      end
      raise UsageError.new("--database (-d) est obligatoire pour choisir la base à restaurer") unless database
      sources = source ? [source] : @config.sources.map(&.name)
      candidates = Inventory.scan(@layout, sources).select { |e| e.database == Layout.safe(database) }
      found = candidates.map(&.source).uniq!
      if found.size > 1
        raise UsageError.new("la base « #{database} » existe dans plusieurs sources (#{found.join(", ")}) : précisez --source")
      end
      if date
        candidates.select! { |e| e.time.year == date.year && e.time.month == date.month && e.time.day == date.day }
      end
      Inventory.latest(candidates).first? ||
        raise UsageError.new("aucune sauvegarde de « #{database} »#{date ? " le #{date.to_s("%Y-%m-%d")}" : ""}")
    end

    private def entry_for_file(file : String, source : String?) : Inventory::Entry
      path = File.expand_path(file)
      raise UsageError.new("fichier introuvable : #{file}") unless File.file?(path)
      raise UsageError.new("ce n'est pas une sauvegarde jawas : #{file}") unless Layout.backup_file?(path)
      relative = Path[path].relative_to(File.expand_path(@layout.root)).parts
      if relative.size == 4 && !relative.first.starts_with?("..")
        source_name, period, db = relative[0], relative[1], relative[2]
      else
        raise UsageError.new("fichier hors du stockage : --source est alors obligatoire") unless source
        source_name, period, db = source, "daily", File.basename(path).split('_').first
      end
      Inventory::Entry.new(source_name, period, db, path, Layout.backup_time(path), File.size(path).to_i64,
        File.exists?("#{path}.sha256"))
    end

    private def source_config(name : String) : Config::SourceConfig
      @config.sources.find { |source| source.name == name } ||
        raise UsageError.new("source « #{name} » absente de la configuration")
    end

    private def original_target(config : Config::SourceConfig, engine : Source, db : String) : String
      if engine.is_a?(Sources::SQLite)
        config.databases.find { |path| engine.db_name(path) == db } || db
      else
        db
      end
    end

    private def with_source(config : Config::SourceConfig, &)
      engine = Source.for(config, @layout.work_dir)
      begin
        yield engine
      ensure
        engine.close
      end
    end
  end
end
