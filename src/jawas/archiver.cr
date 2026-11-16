require "digest/sha256"
require "file_utils"

module Jawas
  # Écrit le dump d'une base dans le stockage : flux du moteur →
  # compresseur → fichier `.part`, renommage atomique, somme SHA-256 au
  # format `sha256sum`, puis liens vers `weekly`/`monthly` et `latest`.
  class Archiver
    def initialize(@layout : Layout, @compressor : Compressor, @latest : Bool)
    end

    def archive(source : Source, db : String, time : Time, periods : Array(Period)) : DumpResult
      started = Time.instant
      begin
        ext = source.extension(db) + @compressor.extension
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
        File.open(part, "w", perm: 0o600) do |file|
          if binary = @compressor.binary
            compress(source, db, file, binary)
          else
            source.dump(db, file)
          end
        end
        File.rename(part, target)
      ensure
        File.delete?(part)
      end
    end

    private def compress(source : Source, db : String, file : File, binary : String) : Nil
      err = IO::Memory.new
      process = Process.new(binary, @compressor.compress_args,
        input: Process::Redirect::Pipe, output: file, error: err)
      begin
        source.dump(db, process.input)
      ensure
        process.input.close
        status = process.wait
      end
      return if status.success?
      raise DumpError.new("#{@compressor.tool} a échoué (code #{status.exit_code}) : #{err.to_s.strip}")
    rescue ex : File::Error
      raise DumpError.new("#{@compressor.tool} : #{ex.message}")
    end

    private def write_checksum(path : String) : String
      digest = Digest::SHA256.new
      File.open(path) do |file|
        buffer = Bytes.new(64 * 1024)
        while (n = file.read(buffer)) > 0
          digest.update(buffer[0, n])
        end
      end
      hex = digest.final.hexstring
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
