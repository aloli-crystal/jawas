module Jawas
  # Rotation des sauvegardes : par période, un fichier plus vieux que
  # la durée de rétention (en jours) est supprimé, *sauf* s'il fait
  # partie des `keep_min` plus récents de sa base. Ce plancher évite
  # qu'une panne prolongée des sauvegardes ne vide le stockage.
  #
  # Une durée de 0 désactive la rotation de la période.
  class Retention
    STALE_PART = 1.day

    def initialize(@layout : Layout, @policy : Config::Retention)
    end

    # Liste (et supprime si `apply`) les fichiers à purger.
    def prune(sources : Array(String), now : Time = Time.local, apply : Bool = false) : Array(PrunedFile)
      pruned = [] of PrunedFile
      sources.each do |source|
        Period.values.each do |period|
          days = @policy.days_for(period)
          next if days <= 0
          each_db_dir(source, period) do |dir|
            candidates(dir, days, now).each do |path, age|
              pruned << PrunedFile.new(path, period.dirname, age)
              remove(path) if apply
            end
            remove_stale_parts(dir, now) if apply
          end
        end
      end
      pruned
    end

    # Fichiers d'un répertoire de base trop anciens, du plus ancien au
    # plus récent, en préservant les `keep_min` plus récents.
    def candidates(dir : String, days : Int32, now : Time) : Array({String, Int32})
      files = Dir.children(dir)
        .map { |name| File.join(dir, name) }
        .select { |path| Layout.backup_file?(path) && !File.symlink?(path) }
        .map { |path| {path, Layout.backup_time(path, now.location)} }
        .sort_by! { |_, time| time }
        .reverse!
      kept = files.first(@policy.keep_min)
      (files - kept)
        .select { |_, time| now - time > days.days }
        .map { |path, time| {path, (now - time).total_days.to_i} }
        .reverse!
    end

    private def each_db_dir(source : String, period : Period, &) : Nil
      base = @layout.period_dir(source, period)
      return unless Dir.exists?(base)
      Dir.children(base).sort.each do |name|
        dir = File.join(base, name)
        yield dir if Dir.exists?(dir) && !File.symlink?(dir)
      end
    end

    private def remove(path : String) : Nil
      File.delete?(path)
      File.delete?("#{path}.sha256")
    end

    private def remove_stale_parts(dir : String, now : Time) : Nil
      Dir.children(dir).each do |name|
        next unless name.ends_with?(".part")
        path = File.join(dir, name)
        File.delete?(path) if now - File.info(path).modification_time > STALE_PART
      end
    end
  end
end
