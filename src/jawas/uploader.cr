module Jawas
  # Échec d'un envoi distant (connexion, refus du récepteur…).
  class UploadError < Error
  end

  # Envoi des sauvegardes vers une destination `[[remote]]`. Toujours en
  # ajout seul : rien n'est jamais supprimé ni remplacé à distance ; la
  # rotation distante est l'affaire d'un `jawas prune` sur l'hôte distant.
  class Uploader
    # Sauvegarde à proposer : chemin relatif à la racine du stockage et,
    # pour une copie weekly/monthly liée au fichier daily, le chemin de
    # celui-ci (le récepteur recrée le lien sans transfert).
    record Item, relative : String, path : String, size : Int64, link_to : String?

    def initialize(@layout : Layout, @remote : Config::RemoteConfig, @log : IO = STDERR)
    end

    # Sauvegardes des `sources` dans les périodes de la destination,
    # daily d'abord (les liens viennent après leur original).
    def items(sources : Array(String)) : Array(Item)
      entries = Inventory.scan(@layout, sources).select { |e| @remote.periods.includes?(e.period) }
      daily = entries.select { |e| e.period == "daily" }.index_by { |e| {e.source, e.database, e.time} }
      order = Period.values.map(&.dirname)
      entries.sort_by { |e| {order.index(e.period) || 0, e.source, e.database, e.time} }.map do |e|
        origin = daily[{e.source, e.database, e.time}]? unless e.period == "daily"
        link = origin.path if origin && File.same?(origin.path, e.path)
        Item.new(@layout.relative(e.path), e.path, e.size, link.try { |path| @layout.relative(path) })
      end
    end

    def upload(sources : Array(String), apply : Bool) : UploadResult
      result = UploadResult.new(@remote.name, @remote.type, @remote.destination, apply)
      list = items(sources)
      result.offered = list.size
      # rclone ne recrée pas les liens : chaque copie est transmise en entier.
      result.offered_bytes = list.sum { |item| item.link_to && @remote.type == "ssh" ? 0_i64 : item.size }
      return result unless apply
      started = Time.instant
      begin
        @remote.type == "ssh" ? ssh(list, result) : rclone(sources, result)
      rescue ex : UploadError
        result.error = ex.message
      end
      result.seconds = (Time.instant - started).total_seconds
      result
    end

    def ssh_args : Array(String)
      args = ["-T", "-o", "BatchMode=yes"]
      @remote.port.try { |port| args.concat(["-p", port.to_s]) }
      @remote.identity.try { |identity| args.concat(["-i", identity]) }
      @remote.ssh_options.each { |option| args.concat(["-o", option]) }
      args << @remote.destination
      args << @remote.command
    end

    def rclone_args(sources : Array(String)) : Array(String)
      args = ["copy", @layout.root, @remote.target.to_s, "--immutable", "-v",
              "--filter", "- *.part", "--filter", "- *.tmp"]
      sources.each do |source|
        @remote.periods.each { |period| args.concat(["--filter", "+ /#{source}/#{period}/**"]) }
      end
      args.concat(["--filter", "- **"])
      @remote.rclone_config.try { |config| args.concat(["--config", config]) }
      args.concat(@remote.extra_args)
    end

    # Contrôle de bout en bout (`jawas check`) : ouvre puis referme une
    # session ; rend le mode annoncé par le récepteur (`apply`/`dry-run`).
    def ping : String
      with_ssh { |session| session.hello.tap { session.finish } }
    end

    private def ssh(list : Array(Item), result : UploadResult) : Nil
      with_ssh do |session|
        mode = session.hello
        raise UploadError.new("le récepteur est en dry-run : ajoutez --apply à sa commande") unless mode == "apply"
        list.each { |item| session.offer(item, result) }
        session.finish
      end
    end

    private def with_ssh(& : Session -> T) : T forall T
      err = IO::Memory.new
      process = begin
        Process.new(@remote.binary, ssh_args, input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe, error: err)
      rescue ex : IO::Error | File::Error
        raise UploadError.new("#{@remote.binary} introuvable ou non exécutable (#{ex.message})")
      end
      value, problem = nil, nil
      begin
        value = yield Session.new(process.output, process.input)
      rescue ex : UploadError | IO::Error
        problem = ex
      end
      process.input.close rescue nil
      status = process.wait
      # Connexion coupée : le message utile est sur la sortie d'erreur
      # de ssh (hôte injoignable, clé refusée…).
      if problem.nil? && !status.success? ||
         (problem.is_a?(IO::Error) || problem.try(&.message.to_s.starts_with?("connexion"))) && !status.success?
        raise UploadError.new(failure("ssh", status, err))
      end
      raise UploadError.new(problem.message.to_s) if problem
      value.as(T)
    end

    private def rclone(sources : Array(String), result : UploadResult) : Nil
      output = IO::Memory.new
      status = begin
        Process.run(@remote.binary, rclone_args(sources), output: output, error: output)
      rescue ex : IO::Error | File::Error
        raise UploadError.new("#{@remote.binary} introuvable ou non exécutable (#{ex.message})")
      end
      log = output.to_s
      # rclone -v : une ligne « Copied (new) » par fichier envoyé.
      result.sent = log.lines.count(&.includes?(": Copied (new)"))
      result.bytes = 0_i64
      result.present = Math.max(result.offered - result.sent, 0)
      raise UploadError.new(failure("rclone", status, output)) unless status.success?
    end

    private def failure(tool : String, status : Process::Status, err : IO::Memory) : String
      lines = err.to_s.lines.map(&.strip).reject(&.empty?)
      detail = lines.reverse.find { |line| line.includes?("ERROR") || line.includes?("rror") } || lines.last?
      "#{tool} a échoué (code #{status.exit_code})#{detail ? " : #{detail}" : ""}"
    end

    # Côté émetteur du protocole décrit dans `Receiver`.
    class Session
      def initialize(@reader : IO, @writer : IO)
      end

      # Salutation ; rend le mode du récepteur (`apply` ou `dry-run`).
      def hello : String
        send "#{Receiver::GREETING} #{Receiver::PROTOCOL}"
        answer = expect
        raise UploadError.new("récepteur : #{answer.lchop("ERR ")}") if answer.starts_with?("ERR")
        parts = answer.split(' ')
        unless parts[0]? == Receiver::GREETING && parts[1]? == Receiver::PROTOCOL.to_s
          raise UploadError.new("réponse inattendue du récepteur : #{answer[0, 120]}")
        end
        parts[2]? || "?"
      end

      def offer(item : Item, result : UploadResult) : Nil
        sha = Session.checksum(item.path)
        if origin = item.link_to
          send "LINK #{item.relative} #{sha} #{origin}"
          case answer = expect
          when "HAVE" then return result.present += 1
          when "OK"   then return result.linked += 1
          when "MISSING" # original absent à distance : envoi complet
          else return result.failures << "#{item.relative} : #{answer.lchop("ERR ")}"
          end
        end
        send "FILE #{item.relative} #{item.size} #{sha}"
        case answer = expect
        when "HAVE" then result.present += 1
        when "SEND"
          File.open(item.path) { |file| IO.copy(file, @writer, item.size) }
          @writer.flush
          reply = expect
          if reply == "OK"
            result.sent += 1
            result.bytes += item.size
          else
            result.failures << "#{item.relative} : #{reply.lchop("ERR ")}"
          end
        else
          result.failures << "#{item.relative} : #{answer.lchop("ERR ")}"
        end
      end

      def finish : Nil
        send "END"
        answer = expect
        raise UploadError.new("fin de session inattendue : #{answer[0, 120]}") unless answer.starts_with?("BYE")
      end

      # Empreinte du `.sha256` local (le récepteur la recontrôle : une
      # sauvegarde altérée sur disque est donc refusée), sinon calculée.
      def self.checksum(path : String) : String
        recorded = File.read("#{path}.sha256").split(' ', 2).first rescue nil
        recorded && recorded.matches?(Receiver::SHA_REGEX) ? recorded : Archiver.sha256(path)
      end

      private def send(line : String) : Nil
        @writer.puts line
        @writer.flush
      end

      private def expect : String
        @reader.gets('\n', Receiver::MAX_LINE, chomp: true) ||
          raise UploadError.new("connexion fermée par le récepteur")
      end
    end
  end
end
