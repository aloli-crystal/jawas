require "file_utils"

module Jawas
  # Orchestration d'une exécution `jawas backup` :
  #
  # 1. verrou exclusif sur le stockage (pas de double exécution) ;
  # 2. hooks `pre` (un échec annule la sauvegarde) ;
  # 3. dump de chaque base de chaque source (un échec n'arrête pas les
  #    autres) ;
  # 4. rotation (sauf `prune: false`) ;
  # 5. envoi vers les `[[remote]]` (sauf `upload: false`) ;
  # 6. hooks `post` avec `JAWAS_STATUS` (`ok` / `failed`) et
  #    `JAWAS_REPORT` (chemin du rapport JSON) ;
  # 7. rapport `last-run.json`.
  #
  # Sans `apply`, rien n'est écrit : le rapport décrit ce qui serait fait.
  class Runner
    getter config : Config
    getter layout : Layout
    @upload = true

    def initialize(@config : Config, @sources : Array(String) = [] of String,
                   @databases : Array(String) = [] of String, @log : IO = STDERR,
                   @remotes : Array(String) = [] of String)
      @layout = Layout.new(@config.storage.dir)
      unless @config.sources.empty?
        unknown = @sources - @config.sources.map(&.name)
        raise ConfigError.new("source(s) inconnue(s) : #{unknown.join(", ")}") unless unknown.empty?
      end
      unknown = @remotes - @config.remotes.map(&.name)
      raise ConfigError.new("destination(s) inconnue(s) : #{unknown.join(", ")}") unless unknown.empty?
    end

    # Noms des sources à traiter. Sans `[[source]]` (hôte qui reçoit des
    # sauvegardes), ce sont les sources présentes dans le stockage.
    def source_names : Array(String)
      return selected_sources.map(&.name) unless @config.sources.empty?
      stored = @layout.stored_sources
      @sources.empty? ? stored : stored & @sources
    end

    def selected_remotes : Array(Config::RemoteConfig)
      @remotes.empty? ? @config.remotes : @config.remotes.select { |remote| @remotes.includes?(remote.name) }
    end

    def selected_sources : Array(Config::SourceConfig)
      @sources.empty? ? @config.sources : @config.sources.select { |source| @sources.includes?(source.name) }
    end

    def backup(apply : Bool, prune : Bool = true, now : Time = Time.local, upload : Bool = true) : Report
      raise ConfigError.new("aucune source déclarée ([[source]]) : rien à sauvegarder") if @config.sources.empty?
      @upload = upload
      report = Report.new(now, apply)
      periods = Calendar.periods_for(now, @config.schedule.weekly_day, @config.schedule.monthly_day)
      if apply
        FileUtils.mkdir_p(@layout.root, 0o700)
        with_lock { run(report, periods, now, prune) }
      else
        plan(report, periods, now, prune)
      end
      report.finished_at = Time.local
      report
    end

    def prune(apply : Bool, now : Time = Time.local) : Array(PrunedFile)
      retention = Retention.new(@layout, @config.retention)
      return retention.prune(source_names, now, apply: false) unless apply
      with_lock { retention.prune(source_names, now, apply: true) }
    end

    # Envoi seul (`jawas upload`), sous le verrou : pas de rotation
    # pendant un transfert.
    def upload(apply : Bool) : Array(UploadResult)
      return send_remotes(apply: false) unless apply
      with_lock { send_remotes(apply: true) }
    end

    private def send_remotes(apply : Bool) : Array(UploadResult)
      selected_remotes.map do |remote|
        @log.puts "→ envoi #{remote.name} (#{remote.type} #{remote.destination})" if apply
        result = Uploader.new(@layout, remote, @log).upload(source_names, apply)
        @log.puts "  ✗ #{result.error}" if result.error
        result.failures.each { |failure| @log.puts "  ✗ #{failure}" }
        result
      end
    end

    private def run(report : Report, periods : Array(Period), now : Time, prune : Bool) : Nil
      unless Hooks.run(@config.hooks.pre, "pre", {} of String => String, @log)
        report.errors << "hook pre en échec : sauvegarde annulée"
        write_report(report)
        return
      end
      archiver = Archiver.new(@layout, @config.compressor, @config.storage.latest, @config.encryptor)
      each_database(report) do |source, db|
        @log.puts "→ #{source.name}/#{db}"
        result = archiver.archive(source, db, now, periods)
        report.dumps << result
        @log.puts "  ✗ #{result.error}" unless result.ok?
      end
      report.pruned.concat(Retention.new(@layout, @config.retention).prune(selected_sources.map(&.name), now, apply: true)) if prune
      report.uploads.concat(send_remotes(apply: true)) if @upload
      report.finished_at = Time.local
      write_report(report)
      env = {"JAWAS_STATUS" => report.ok? ? "ok" : "failed", "JAWAS_REPORT" => @layout.report_path}
      report.errors << "hook post en échec" unless Hooks.run(@config.hooks.post, "post", env, @log)
      write_report(report) unless report.errors.empty?
    ensure
      Dir.delete(@layout.work_dir) if Dir.exists?(@layout.work_dir) && Dir.empty?(@layout.work_dir)
    end

    # Dry-run : liste les bases (connexion en lecture seule) et les
    # fichiers que la rotation supprimerait.
    private def plan(report : Report, periods : Array(Period), now : Time, prune : Bool) : Nil
      suffix = Archiver.new(@layout, @config.compressor, false, @config.encryptor).suffix
      each_database(report) do |source, db|
        ext = source.extension(db) + suffix
        path = @layout.file_path(source.name, periods.first, db, now, ext)
        report.dumps << DumpResult.new(source.name, db, periods.map(&.dirname), path)
      end
      report.pruned.concat(prune(apply: false, now: now)) if prune
      report.uploads.concat(send_remotes(apply: false)) if @upload
    end

    private def each_database(report : Report, &) : Nil
      selected_sources.each do |source_config|
        source = Source.for(source_config, @layout.work_dir)
        begin
          dbs = source.databases
          dbs = dbs.select { |db| @databases.includes?(db) } unless @databases.empty?
          dbs.each { |db| yield source, db }
        rescue ex : DumpError | ConfigError
          report.errors << "#{source_config.name} : #{ex.message}"
          @log.puts "✗ #{source_config.name} : #{ex.message}"
        ensure
          source.close
        end
      end
    end

    private def write_report(report : Report) : Nil
      File.write(@layout.report_path, report.to_pretty_json + "\n", perm: 0o600)
    rescue ex : File::Error
      @log.puts "✗ rapport non écrit : #{Access.describe(ex)}"
    end

    private def with_lock(&)
      File.open(@layout.lock_path, "a", perm: 0o600) do |file|
        begin
          file.flock_exclusive(blocking: false)
        rescue IO::Error
          raise LockError.new("une autre exécution de jawas tient le verrou #{@layout.lock_path}")
        end
        begin
          yield
        ensure
          file.flock_unlock
        end
      end
    end
  end

  # Commandes shell déclarées dans `[hooks]`, exécutées via `sh -c`.
  module Hooks
    def self.run(commands : Array(String), stage : String, env : Hash(String, String), log : IO) : Bool
      commands.all? do |command|
        log.puts "→ hook #{stage} : #{command}"
        status = Process.run("/bin/sh", ["-c", command], env: env, output: log, error: log)
        log.puts "  ✗ code #{status.exit_code}" unless status.success?
        status.success?
      end
    end
  end
end
