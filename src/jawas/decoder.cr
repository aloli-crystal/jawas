module Jawas
  # Relit le contenu d'une sauvegarde : fichier → `age -d` (si `.age`)
  # → décompression → flux remis à l'appelant. Inverse de `Archiver`.
  #
  # Une sauvegarde chiffrée exige une identité age (clé privée, fichier
  # `age-keygen` ou clé SSH) : elle n'est jamais sur le serveur, elle est
  # fournie au moment de la relecture (`--identity`).
  class Decoder
    getter path : String

    def initialize(@path : String, @identity : String? = nil, @age_binary : String = "age")
    end

    def encrypted? : Bool
      @path.ends_with?(Encryptor::EXTENSION)
    end

    def compressor : Compressor
      Compressor.for_path(@path)
    end

    # Nom de la sauvegarde sans compression ni chiffrement
    # (`app_….daily.sql`), dont l'extension désigne le format.
    def plain_name : String
      name = File.basename(@path).rchop(Encryptor::EXTENSION)
      name.rchop(compressor.extension)
    end

    def filters : Array(Filter)
      list = [] of Filter
      if encrypted?
        identity = @identity || raise DumpError.new("sauvegarde chiffrée : --identity (clé privée age) requis")
        raise DumpError.new("identité illisible : #{identity}") unless File::Info.readable?(identity)
        binary = Process.find_executable(@age_binary) || raise DumpError.new("#{@age_binary} introuvable")
        list << Filter.new(@age_binary, binary, ["--decrypt", "--identity", identity])
      end
      comp = compressor
      if bin = comp.binary
        found = Process.find_executable(bin) || raise DumpError.new("#{bin} introuvable")
        list << Filter.new(comp.tool, found, comp.decompress_args)
      end
      list
    end

    # Ouvre le flux décodé. Le bloc doit le lire jusqu'au bout ; les
    # échecs des filtres sont levés ensuite (`DumpError`), le premier en
    # amont étant la cause (un `age` qui échoue tronque la suite).
    def open(& : IO ->) : Nil
      stages = filters
      File.open(@path) do |file|
        if stages.empty?
          yield file
          next
        end
        running = [] of {Filter, Process, IO::Memory}
        input = file.as(IO::FileDescriptor)
        stages.each do |filter|
          err = IO::Memory.new
          process = Process.new(filter.binary, filter.args,
            input: input, output: Process::Redirect::Pipe, error: err)
          input.close unless input.same?(file)
          running << {filter, process, err}
          input = process.output
        end
        # Une erreur du lecteur (contenu tronqué…) cède la place à celle
        # d'un filtre : c'est elle la cause. Si le lecteur s'arrête en
        # route (chargement refusé par le serveur…), le reste du flux est
        # vidé pour que les filtres finissent proprement et que l'erreur
        # du lecteur ne soit pas masquée par un « Broken pipe ».
        reader_error = nil
        begin
          yield input
        rescue ex
          reader_error = ex
          begin
            input.skip_to_end
          rescue IO::Error
          end
        end
        input.close
        failure = running.compact_map do |filter, process, err|
          status = process.wait
          next if status.success?
          detail = err.to_s.lines.map(&.strip).find(&.presence)
          "#{filter.name} a échoué (code #{status.exit_code})#{detail ? " : #{detail}" : ""}"
        end.first?
        raise DumpError.new(failure) if failure
        raise reader_error if reader_error
      end
    end
  end
end
