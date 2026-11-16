require "json"

module Jawas
  # Contrôle d'une sauvegarde à trois niveaux :
  #
  # 1. *empreinte* — le fichier correspond à son `.sha256` ;
  # 2. *archive* — elle se déchiffre (si une identité est fournie) et se
  #    décompresse jusqu'au bout ;
  # 3. *contenu* — le dump est complet : marque de fin de `mysqldump` ou
  #    de `pg_dump`, en-tête `PGDMP` du format custom, `COMMIT;` final
  #    d'un dump SQLite, en-tête et `PRAGMA integrity_check` d'une copie
  #    SQLite.
  #
  # Sans identité, une sauvegarde chiffrée n'est contrôlée qu'au niveau 1
  # (et sur son en-tête age) : les niveaux 2 et 3 sont « ignorés ».
  class Verifier
    OK      = "ok"
    FAILED  = "échec"
    SKIPPED = "ignoré"

    class Result
      include JSON::Serializable

      getter source : String
      getter database : String
      getter path : String
      property checksum : String = SKIPPED
      property archive : String = SKIPPED
      property content : String = SKIPPED
      property detail : String? = nil

      def initialize(@source, @database, @path)
      end

      def ok? : Bool
        {checksum, archive, content}.none?(FAILED)
      end

      def complete? : Bool
        {checksum, archive, content}.all?(OK)
      end

      def fail(level : Symbol, message : String) : Nil
        case level
        when :checksum then @checksum = FAILED
        when :archive  then @archive = FAILED
        else                @content = FAILED
        end
        @detail = message
      end
    end

    TAIL = 4096

    def initialize(@identity : String? = nil, @work_dir : String = Dir.tempdir,
                   @age_binary : String = "age")
    end

    # `engine` : moteur de la source (pour la marque de fin attendue),
    # nil si la source n'est plus dans la configuration.
    def verify(path : String, source : String, database : String, engine : String?) : Result
      result = Result.new(source, database, path)
      return result unless verify_checksum(result)
      decoder = Decoder.new(path, @identity, @age_binary)
      if decoder.encrypted? && @identity.nil?
        verify_age_header(result)
        return result
      end
      verify_stream(result, decoder, engine)
      result
    end

    private def verify_checksum(result : Result) : Bool
      sidecar = "#{result.path}.sha256"
      unless File.exists?(sidecar)
        result.fail(:checksum, "fichier .sha256 absent")
        return false
      end
      expected = File.read(sidecar).split(/\s+/, 2).first
      actual = Archiver.sha256(result.path)
      if expected == actual
        result.checksum = OK
        true
      else
        result.fail(:checksum, "empreinte différente : #{actual[0, 12]}… au lieu de #{expected[0, 12]}…")
        false
      end
    rescue ex : File::Error | IO::Error
      result.fail(:checksum, ex.message.to_s)
      false
    end

    private def verify_age_header(result : Result) : Nil
      header = File.open(result.path) { |file| file.read_string(Math.min(21, file.size.to_i)) }
      if header == "age-encryption.org/v1"
        result.detail = "chiffrée : --identity pour contrôler l'archive et le contenu"
      else
        result.fail(:archive, "en-tête age absent")
      end
    end

    private def verify_stream(result : Result, decoder : Decoder, engine : String?) : Nil
      format = File.extname(decoder.plain_name)
      sqlite_copy = format == ".sqlite3" ? temp_path : nil
      head = Bytes.empty
      tail = IO::Memory.new
      size = 0_i64
      begin
        decoder.open do |io|
          copy = sqlite_copy.try { |path| File.open(path, "w", perm: 0o600) }
          begin
            buffer = Bytes.new(64 * 1024)
            while (n = io.read(buffer)) > 0
              chunk = buffer[0, n]
              head = chunk[0, Math.min(16, n)].dup if size.zero?
              size += n
              copy.try &.write(chunk)
              keep_tail(tail, chunk)
            end
          ensure
            copy.try &.close
          end
        end
        result.archive = OK
        check_content(result, format, engine, head, tail.to_s, size, sqlite_copy)
      rescue ex : DumpError | IO::Error | File::Error
        result.fail(:archive, ex.message.to_s)
      ensure
        sqlite_copy.try { |path| File.delete?(path) }
      end
    end

    private def keep_tail(tail : IO::Memory, chunk : Bytes) : Nil
      if chunk.size >= TAIL
        tail.clear
        tail.write(chunk[chunk.size - TAIL, TAIL])
        return
      end
      kept = tail.to_slice
      overflow = kept.size + chunk.size - TAIL
      if overflow > 0
        rest = kept[overflow, kept.size - overflow].dup
        tail.clear
        tail.write(rest)
      end
      tail.write(chunk)
    end

    private def check_content(result : Result, format : String, engine : String?, head : Bytes,
                              tail : String, size : Int64, sqlite_copy : String?) : Nil
      problem = if size.zero?
                  "dump vide"
                else
                  case format
                  when ".pgdump"  then "en-tête PGDMP absent" unless String.new(head).starts_with?("PGDMP")
                  when ".sqlite3" then sqlite_problem(head, sqlite_copy)
                  else                 sql_problem(engine, tail)
                  end
                end
      if problem
        result.fail(:content, problem)
      else
        result.content = OK
      end
    end

    private def sql_problem(engine : String?, tail : String) : String?
      case engine
      when "mysql", "mariadb"
        "marque « -- Dump completed » absente (dump tronqué ?)" unless tail.includes?("-- Dump completed")
      when "postgresql"
        "marque « dump complete » absente (dump tronqué ?)" unless tail.includes?("dump complete")
      when "sqlite"
        "« COMMIT; » final absent (dump tronqué ?)" unless tail.rstrip.ends_with?("COMMIT;")
      end
    end

    private def sqlite_problem(head : Bytes, copy : String?) : String?
      return "en-tête SQLite absent" unless String.new(head).starts_with?("SQLite format 3")
      return unless copy && (binary = Process.find_executable("sqlite3"))
      output = IO::Memory.new
      status = Process.run(binary, ["-readonly", copy, "PRAGMA integrity_check"], output: output, error: output)
      verdict = output.to_s.strip
      "integrity_check : #{verdict.lines.first?}" unless status.success? && verdict == "ok"
    end

    private def temp_path : String
      Dir.mkdir_p(@work_dir, 0o700)
      File.tempname("jawas-verify-", ".sqlite3", dir: @work_dir)
    end
  end
end
