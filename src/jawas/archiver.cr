require "digest/sha256"
require "file_utils"

module Jawas
  # Écrit le dump d'une base dans le stockage : flux du moteur →
  # compresseur → chiffrement age → fichier `.part`, renommage atomique,
  # somme SHA-256 (du fichier final) au format `sha256sum`, puis liens
  # vers `weekly`/`monthly` et `latest`.
  class Archiver
    def initialize(@layout : Layout, @compressor : Compressor, @latest : Bool,
                   @encryptor : Encryptor? = nil)
    end

    # Extension ajoutée à celle du moteur (`.zst.age`, `.gz`…).
    def suffix : String
      @compressor.extension + (@encryptor.try(&.extension) || "")
    end

    def archive(source : Source, db : String, time : Time, periods : Array(Period)) : DumpResult
      started = Time.instant
      begin
        ext = source.extension(db) + suffix
        primary = @layout.file_path(source.name, periods.first, db, time, ext)
        FileUtils.mkdir_p(File.dirname(primary), 0o700)
        write(source, db, primary)
        digest = write_checksum(primary)
        periods[1..].each do |period|
          link(primary, @layout.file_path(source.name, period, db, time, ext))
        end
        update_latest(source.name, db, ext, primary) if @latest
        DumpResult.new(source.name, db, periods.map(&.dirname), primary, File.size(primary).to_i64,
          digest, (Time.instant - started).total_seconds)
      rescue ex : DumpError | File::Error | IO::Error
        DumpResult.new(source.name, db, periods.map(&.dirname),
          seconds: (Time.instant - started).total_seconds, error: ex.message)
      end
    end

    private def write(source : Source, db : String, target : String) : Nil
      part = "#{target}.part"
      begin
        filters = [@compressor.filter, @encryptor.try(&.filter)].compact
        File.open(part, "w", perm: 0o600) do |file|
          filters.empty? ? source.dump(db, file) : pipe(source, db, filters, file)
        end
        File.rename(part, target)
      ensure
        File.delete?(part)
      end
    end

    # Chaîne les filtres : le moteur écrit dans le premier, chacun écrit
    # dans le suivant, le dernier dans le fichier. Lancés du dernier au
    # premier ; la copie de l'entrée du suivant gardée par jawas est
    # refermée aussitôt, sinon il n'en verrait jamais la fin.
    private def pipe(source : Source, db : String, filters : Array(Filter), file : File) : Nil
      stages = [] of {Filter, Process, IO::Memory}
      output = file.as(IO::FileDescriptor)
      filters.reverse_each do |filter|
        err = IO::Memory.new
        process = Process.new(filter.binary, filter.args,
          input: Process::Redirect::Pipe, output: output, error: err)
        output.close unless output.same?(file)
        stages.unshift({filter, process, err})
        output = process.input
      end
      begin
        source.dump(db, output)
      rescue ex : DumpError | IO::Error
        output.close
        # Un filtre mort (destinataire refusé…) fait échouer le moteur
        # sur un tube cassé : c'est l'erreur du filtre qui compte.
        raise filter_failure(stages) || ex
      end
      output.close
      if failure = filter_failure(stages)
        raise failure
      end
    rescue ex : File::Error
      raise DumpError.new(ex.message)
    end

    # Attend tous les filtres. Quand l'un meurt, ceux d'avant échouent à
    # leur tour sur un tube cassé : seul le plus en aval est rapporté,
    # avec la première ligne de son message.
    private def filter_failure(stages : Array({Filter, Process, IO::Memory})) : DumpError?
      failures = stages.compact_map do |filter, process, err|
        status = process.wait
        next if status.success?
        detail = err.to_s.lines.map(&.strip).find(&.presence)
        "#{filter.name} a échoué (code #{status.exit_code})#{detail ? " : #{detail}" : ""}"
      end
      DumpError.new(failures.last) unless failures.empty?
    end

    # Empreinte SHA-256 (hexadécimale) d'un fichier, lu par blocs.
    def self.sha256(path : String) : String
      digest = Digest::SHA256.new
      File.open(path) do |file|
        buffer = Bytes.new(64 * 1024)
        while (n = file.read(buffer)) > 0
          digest.update(buffer[0, n])
        end
      end
      digest.final.hexstring
    end

    private def write_checksum(path : String) : String
      hex = Archiver.sha256(path)
      File.write("#{path}.sha256", "#{hex}  #{File.basename(path)}\n", perm: 0o600)
      hex
    end

    # Lien physique (zéro octet de plus), copie si le système de
    # fichiers ne le permet pas. La somme est réécrite : le nom diffère.
    private def link(primary : String, target : String) : Nil
      FileUtils.mkdir_p(File.dirname(target), 0o700)
      File.delete?(target)
      begin
        File.link(primary, target)
      rescue File::Error
        FileUtils.cp(primary, target)
      end
      hex = File.read("#{primary}.sha256").split(' ', 2).first
      File.write("#{target}.sha256", "#{hex}  #{File.basename(target)}\n", perm: 0o600)
    end

    private def update_latest(source : String, db : String, ext : String, primary : String) : Nil
      dir = @layout.latest_dir(source)
      FileUtils.mkdir_p(dir, 0o700)
      link_path = File.join(dir, "#{Layout.safe(db)}#{ext}")
      relative = Path[primary].relative_to(dir).to_s
      tmp = "#{link_path}.tmp"
      File.delete?(tmp)
      File.symlink(relative, tmp)
      File.rename(tmp, link_path)
    end
  end
end
