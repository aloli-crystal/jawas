module Jawas::CLI
  # Implémentation des sous-commandes (sorties texte ou JSON).
  module Commands
    def self.upload(runner : Runner, options : Options) : Int32
      raise UsageError.new("aucune destination déclarée ([[remote]])") if runner.config.remotes.empty?
      results = runner.upload(apply: options.apply?)
      if options.json?
        puts results.to_pretty_json
      elsif !options.quiet? || !results.all?(&.ok?)
        print_uploads(results)
        puts dry_run_hint unless options.apply?
      end
      results.all?(&.ok?) ? 0 : 2
    end

    # Récepteur : la racine vient de `--storage` ou de la configuration
    # locale, jamais de l'émetteur.
    def self.receive(options : Options) : Int32
      root = options.storage || Config.load(Config.locate(options.config, options.no_user_config?)).storage.dir
      Receiver.new(root, STDIN, STDOUT, options.apply?).run
    end

    def self.backup(runner : Runner, options : Options) : Int32
      report = runner.backup(apply: options.apply?, prune: options.prune?, upload: options.upload?)
      if options.json?
        puts report.to_pretty_json
      elsif !options.quiet? || !report.ok?
        print_backup(report)
      end
      report.ok? ? 0 : 2
    end

    def self.prune(runner : Runner, options : Options) : Int32
      pruned = runner.prune(apply: options.apply?)
      if options.json?
        puts pruned.to_pretty_json
      elsif !options.quiet?
        print_pruned(pruned, options.apply?)
        puts dry_run_hint unless options.apply?
      end
      0
    end

    def self.list(runner : Runner, options : Options) : Int32
      entries = Inventory.scan(runner.layout, runner.source_names)
      entries.select! { |e| options.databases.includes?(e.database) } unless options.databases.empty?
      if options.json?
        puts entries.to_pretty_json
        return 0
      end
      if entries.empty?
        puts "Aucune sauvegarde dans #{runner.layout.root}"
        return 0
      end
      entries.each do |e|
        mark = e.checksum ? (e.encrypted ? "🔒" : " ") : "!"
        puts "#{mark} #{e.source.ljust(14)} #{e.period.ljust(8)} #{e.database.ljust(24)} " \
             "#{e.time.to_s("%Y-%m-%d %H:%M")}  #{Jawas.human_size(e.size).rjust(10)}"
      end
      puts "#{entries.size} sauvegarde(s), #{Jawas.human_size(entries.sum(&.size))} (liens physiques comptés une fois par période)"
      0
    end

    def self.verify(runner : Runner, options : Options) : Int32
      entries = Inventory.scan(runner.layout, runner.source_names)
      unless options.databases.empty?
        wanted = options.databases.map { |db| Layout.safe(db) }
        entries.select! { |e| wanted.includes?(e.database) }
      end
      entries = Inventory.latest(entries) unless options.all?
      engines = runner.selected_sources.to_h { |source| {source.name, source.engine} }
      verifier = Verifier.new(options.identity, runner.layout.work_dir,
        runner.config.encryptor.try(&.binary_name) || "age")
      results = entries.map { |e| verifier.verify(e.path, e.source, e.database, engines[e.source]?) }
      if options.json?
        puts results.to_pretty_json
      else
        print_verify(results, options.quiet?)
      end
      results.all?(&.ok?) ? 0 : 2
    end

    def self.restore(runner : Runner, options : Options) : Int32
      if options.sources.size > 1 || options.databases.size > 1
        raise UsageError.new("restore : une seule source et une seule base à la fois")
      end
      restorer = Restorer.new(runner.config, options.identity, options.quiet? ? IO::Memory.new : STDERR)
      plan = restorer.plan(options.sources.first?, options.databases.first?, options.file, options.date,
        options.into, options.replace?)
      if options.json? && !options.apply?
        puts plan.to_pretty_json
        return 0
      end
      print_plan(plan)
      unless options.apply?
        puts dry_run_hint
        return 0
      end
      restorer.run(plan)
      puts "✓ #{plan.source}/#{plan.database} restaurée dans #{plan.target}"
      0
    rescue ex : DumpError
      puts "✗ restauration : #{ex.message}"
      2
    end

    private def self.print_plan(plan : Restorer::Plan) : Nil
      puts "Sauvegarde : #{plan.path}"
      puts "Cible      : #{plan.target}#{plan.exists? ? " (existe, sera ÉCRASÉE)" : " (sera créée)"}"
      puts "⚠ la cible est la base d'origine" if plan.original?
      if plan.exists? && plan.replace? && !plan.atomic?
        puts "  (la base est supprimée puis recréée : en cas d'échec du chargement, elle reste vide ou partielle ;"
        puts "   restaurez d'abord dans une base jetable pour vérifier)"
      end
    end

    private def self.print_verify(results : Array(Verifier::Result), quiet : Bool) : Nil
      results.each do |result|
        next if quiet && result.ok?
        mark = result.ok? ? (result.complete? ? "✓" : "·") : "✗"
        puts "#{mark} #{result.source}/#{result.database}  empreinte #{result.checksum}, archive #{result.archive}, contenu #{result.content}" \
             "#{result.detail ? " — #{result.detail}" : ""}"
        puts "    #{result.path}" unless result.ok?
      end
      failed = results.count { |result| !result.ok? }
      partial = results.count { |result| result.ok? && !result.complete? }
      puts "#{results.size} sauvegarde(s) : #{results.size - failed - partial} complète(s), " \
           "#{partial} partielle(s), #{failed} en échec" unless quiet && failed.zero?
    end

    def self.check(runner : Runner, options : Options) : Int32
      failures = 0
      config = runner.config
      puts "Configuration : #{config.path}"
      failures += check_storage(config.storage.dir)
      if binary = config.compressor.binary
        failures += report_line(Process.find_executable(binary), "compresseur #{binary}")
      end
      if encryptor = config.encryptor
        failures += check_encryption(encryptor)
      end
      runner.selected_sources.each do |source_config|
        failures += check_source(source_config, runner.layout.work_dir)
      end
      puts "Aucune [[source]] : configuration de réception, rotation et vérification seules" if config.sources.empty?
      runner.selected_remotes.each do |remote|
        failures += check_remote(runner.layout, remote)
      end
      puts failures.zero? ? "✓ tout est prêt" : "✗ #{failures} problème(s)"
      failures.zero? ? 0 : 1
    end

    private def self.check_source(source_config : Config::SourceConfig, work_dir : String) : Int32
      puts "Source #{source_config.name} (#{source_config.engine})"
      failures = 0
      if file = source_config.password_file
        failures += check_password_file(file)
      end
      source = Source.for(source_config, work_dir)
      begin
        source.binaries.each { |b| puts "  ✓ #{b}" }
        dbs = source.databases
        puts "  ✓ #{dbs.size} base(s) : #{dbs.join(", ")}"
      rescue ex : DumpError | ConfigError | File::Error
        puts "  ✗ #{Access.message(ex)}"
        failures += 1
      ensure
        source.close
      end
      failures
    end

    # Illisible : échec (le dump échouerait). Lisible par d'autres :
    # simple avertissement.
    private def self.check_password_file(file : String) : Int32
      if problem = Access.unreadable(file)
        puts "  ✗ password_file : #{problem}"
        return 1
      end
      if File.info(file).permissions.value & 0o077 != 0
        puts "  ! #{file} est lisible par le groupe ou les autres (chmod 600 conseillé)"
      end
      0
    rescue ex : File::Error
      puts "  ✗ password_file : #{Access.describe(ex)}"
      1
    end

    # ssh : ouvre réellement une session (clé, commande forcée, mode
    # apply). rclone : exécutable et fichier de configuration seulement.
    private def self.check_remote(layout : Layout, remote : Config::RemoteConfig) : Int32
      label = "destination #{remote.name} (#{remote.type} #{remote.destination})"
      unless Process.find_executable(remote.binary)
        puts "✗ #{label} — #{remote.binary} introuvable"
        return 1
      end
      if remote.type == "rclone"
        config = remote.rclone_config
        return report_line(config.nil? || File.file?(config) ? remote.binary : nil,
          "#{label}#{config ? ", configuration #{config}" : ""}")
      end
      mode = Uploader.new(layout, remote, IO::Memory.new).ping
      if mode == "apply"
        puts "✓ #{label} : récepteur joint"
        0
      else
        puts "✗ #{label} : récepteur en #{mode} (ajoutez --apply à sa commande)"
        1
      end
    rescue ex : UploadError
      puts "✗ #{label} — #{ex.message}"
      1
    end

    private def self.check_encryption(encryptor : Encryptor) : Int32
      count = encryptor.recipients.size
      label = "chiffrement #{encryptor.binary_name} : #{count} destinataire(s)" \
              "#{encryptor.recipients_file.try { |file| " + #{file}" }}"
      if error = encryptor.self_test
        puts "✗ #{label} — #{error}"
        1
      else
        puts "✓ #{label}"
        0
      end
    end

    # Un parent non traversable (ex. `/var/backups` en `root:wheel 0750`
    # pour l'utilisateur `postgres`) est un échec signalé, pas un plantage.
    private def self.check_storage(dir : String) : Int32
      label = "stockage #{dir}"
      if Access.blocker(dir)
        puts "✗ #{label} — #{Access.denied(dir)}"
        return 1
      end
      probe = dir
      until Dir.exists?(probe) || probe == "/"
        probe = File.dirname(probe)
      end
      if File::Info.writable?(probe) && File::Info.executable?(probe)
        puts "✓ #{label}#{probe == dir ? "" : " (sera créé)"}"
        0
      else
        puts "✗ #{label} — #{probe} n'est pas accessible en écriture pour l'utilisateur #{Access.user}" \
             "#{Access.ownership(probe).try { |rights| " (#{rights})" }}"
        1
      end
    rescue ex : File::Error
      puts "✗ #{label} — #{Access.describe(ex)}"
      1
    end

    private def self.report_line(ok : String?, label : String) : Int32
      puts ok ? "✓ #{label}" : "✗ #{label}"
      ok ? 0 : 1
    end

    private def self.print_backup(report : Report) : Nil
      applied = report.applied?
      report.dumps.each do |dump|
        if !dump.ok?
          puts "✗ #{dump.source}/#{dump.database} : #{dump.error}"
        elsif applied
          puts "✓ #{dump.source}/#{dump.database} [#{dump.periods.join("+")}] #{Jawas.human_size(dump.size)} " \
               "en #{dump.seconds.round(1)} s → #{dump.path}"
        else
          puts "· #{dump.source}/#{dump.database} [#{dump.periods.join("+")}] → #{dump.path}"
        end
      end
      report.errors.each { |e| puts "✗ #{e}" }
      print_pruned(report.pruned, applied)
      print_uploads(report.uploads)
      if applied
        puts "#{report.dumps.count(&.ok?)}/#{report.dumps.size} base(s), #{Jawas.human_size(report.total_size)}"
      else
        puts dry_run_hint
      end
    end

    private def self.print_uploads(results : Array(UploadResult)) : Nil
      results.each do |upload|
        label = "#{upload.remote} (#{upload.type} #{upload.destination})"
        if !upload.applied?
          puts "· envoi #{label} : #{upload.offered} sauvegarde(s) proposée(s), #{Jawas.human_size(upload.offered_bytes)} au plus"
        elsif error = upload.error
          puts "✗ envoi #{label} : #{error}"
        else
          linked = upload.linked > 0 ? ", #{upload.linked} lien(s)" : ""
          size = upload.type == "ssh" ? " (#{Jawas.human_size(upload.bytes)})" : ""
          puts "#{upload.ok? ? "✓" : "✗"} envoi #{label} : #{upload.sent} envoyée(s)#{size}" \
               "#{linked}, #{upload.present} déjà présente(s) en #{upload.seconds.round(1)} s"
        end
        upload.failures.each { |failure| puts "    ✗ #{failure}" }
      end
    end

    private def self.print_pruned(pruned : Array(PrunedFile), applied : Bool) : Nil
      verb = applied ? "supprimé" : "à supprimer"
      pruned.each { |entry| puts "- #{verb} (#{entry.period}, #{entry.age_days} j) #{entry.path}" }
    end

    private def self.dry_run_hint : String
      "(dry-run : rien n'a été modifié ; relancez avec --apply pour exécuter)"
    end
  end
end
