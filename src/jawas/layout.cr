module Jawas
  # Arborescence du répertoire de stockage :
  #
  # ```text
  # <dir>/
  #   <source>/
  #     daily/<base>/<base>_2026-11-16_03h00.daily.sql.zst
  #     daily/<base>/<base>_2026-11-16_03h00.daily.sql.zst.sha256
  #     weekly/<base>/…             (liens physiques vers daily)
  #     monthly/<base>/…
  #     latest/<base>.sql.zst  →  ../daily/<base>/<dernier fichier>
  #   .work/                        (fichiers temporaires, 0700)
  #   .lock
  #   last-run.json                 (rapport de la dernière exécution)
  # ```
  struct Layout
    STAMP_FORMAT = "%Y-%m-%d_%Hh%M"
    STAMP_REGEX  = /_(\d{4}-\d{2}-\d{2}_\d{2}h\d{2})\.(daily|weekly|monthly)\./

    getter root : String

    def initialize(@root : String)
    end

    def work_dir : String
      File.join(@root, ".work")
    end

    def lock_path : String
      File.join(@root, ".lock")
    end

    def report_path : String
      File.join(@root, "last-run.json")
    end

    def source_dir(source : String) : String
      File.join(@root, source)
    end

    def period_dir(source : String, period : Period) : String
      File.join(@root, source, period.dirname)
    end

    def db_dir(source : String, period : Period, db : String) : String
      File.join(period_dir(source, period), Layout.safe(db))
    end

    def latest_dir(source : String) : String
      File.join(@root, source, "latest")
    end

    def file_name(db : String, time : Time, period : Period, extension : String) : String
      "#{Layout.safe(db)}_#{time.to_s(STAMP_FORMAT)}.#{period.dirname}#{extension}"
    end

    def file_path(source : String, period : Period, db : String, time : Time, extension : String) : String
      File.join(db_dir(source, period, db), file_name(db, time, period, extension))
    end

    # Nom de fichier sûr : tout ce qui n'est pas [A-Za-z0-9._-] devient `_`.
    def self.safe(name : String) : String
      cleaned = name.gsub(/[^A-Za-z0-9._-]/, "_")
      cleaned.starts_with?('.') ? "_#{cleaned[1..]}" : cleaned
    end

    # Date de prise d'une sauvegarde, lue dans son nom (robuste à une
    # copie qui ne préserve pas les dates), sinon date de modification.
    def self.backup_time(path : String, location : Time::Location = Time::Location.local) : Time
      if m = File.basename(path).match(STAMP_REGEX)
        Time.parse(m[1], STAMP_FORMAT, location)
      else
        File.info(path).modification_time
      end
    end

    # Vrai pour un fichier de sauvegarde (ni somme de contrôle, ni
    # fichier partiel).
    def self.backup_file?(path : String) : Bool
      name = File.basename(path)
      name.matches?(STAMP_REGEX) && !name.ends_with?(".sha256") && !name.ends_with?(".part")
    end
  end
end
