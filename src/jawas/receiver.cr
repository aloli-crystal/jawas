require "digest/sha256"
require "file_utils"

module Jawas
  # Erreur de protocole entre `jawas upload` et `jawas receive`.
  class ProtocolError < Error
  end

  # Récepteur `jawas receive` : côté distant d'un `[[remote]]` de type
  # `ssh`. Il lit les sauvegardes sur son entrée et répond sur sa sortie
  # standard ; il est fait pour être la commande forcée d'une clé ssh :
  #
  # ```text
  # command="jawas receive -S /srv/jawas/web1 --apply",restrict ssh-ed25519 AAAA… jawas@web1
  # ```
  #
  # Garanties (« ajout seul ») :
  #
  # * la racine est fixée côté récepteur (`--storage`), jamais par
  #   l'émetteur ; les chemins reçus sont validés (`Layout.valid_relative?`) ;
  # * un fichier existant n'est jamais remplacé ni supprimé : même
  #   empreinte → `HAVE`, empreinte différente → refus ;
  # * chaque fichier est écrit dans un `.part`, son empreinte SHA-256
  #   contrôlée à l'arrivée, puis renommé ; le `.sha256` est écrit par le
  #   récepteur.
  #
  # Protocole (lignes ASCII, version 1) :
  #
  # ```text
  # → JAWAS-RECEIVE 1
  # ← JAWAS-RECEIVE 1 apply|dry-run <version>         (ou ERR <message>)
  # → FILE <chemin> <taille> <sha256>
  # ← HAVE | ERR <message> | SEND, puis <taille> octets → OK | ERR <message>
  # → LINK <chemin> <sha256> <chemin existant>
  # ← HAVE | OK | MISSING | ERR <message>
  # → END
  # ← BYE <fichiers> <liens> <octets>
  # ```
  #
  # Sans `--apply`, le récepteur annonce `dry-run`, lit et contrôle les
  # données mais n'écrit rien.
  class Receiver
    PROTOCOL  = 1
    GREETING  = "JAWAS-RECEIVE"
    SHA_REGEX = /\A[0-9a-f]{64}\z/
    MAX_LINE  = 4096

    getter files = 0
    getter links = 0
    getter bytes = 0_i64

    def initialize(@root : String, @input : IO, @output : IO, @apply : Bool = true)
    end

    # Code de sortie : 0 si la session s'est terminée par `END`.
    def run : Int32
      return 1 unless read_line == "#{GREETING} #{PROTOCOL}" || refuse("protocole inattendu")
      if @apply
        FileUtils.mkdir_p(@root, 0o700)
        with_lock { session }
      else
        session
      end
    rescue ex : LockError
      refuse(ex.message.to_s)
      1
    rescue ex : File::Error
      # Stockage distant inaccessible : l'émetteur reçoit la raison.
      refuse(Access.describe(ex)) rescue nil
      1
    rescue ProtocolError | IO::Error
      1
    end

    private def session : Int32
      reply "#{GREETING} #{PROTOCOL} #{@apply ? "apply" : "dry-run"} #{VERSION}"
      while line = read_line
        verb, _, rest = line.partition(' ')
        case verb
        when "FILE" then receive_file(rest.split(' '))
        when "LINK" then receive_link(rest.split(' '))
        when "END"
          reply "BYE #{@files} #{@links} #{@bytes}"
          return 0
        else
          refuse("commande inconnue « #{verb} »")
          return 1
        end
      end
      1
    end

    private def receive_file(args : Array(String)) : Nil
      relative, size, sha = args[0]?, args[1]?.try(&.to_i64?), args[2]?
      return refuse("FILE : arguments invalides") unless relative && size && size >= 0 && sha && sha.matches?(SHA_REGEX)
      return refuse("chemin refusé : #{relative}") unless Layout.valid_relative?(relative)
      target = File.join(@root, relative)
      return if existing?(target, sha)
      reply "SEND"
      if store(target, size, sha)
        @files += 1
        @bytes += size
        reply "OK"
      else
        reply "ERR empreinte différente à l'arrivée : #{relative}"
      end
    end

    private def receive_link(args : Array(String)) : Nil
      relative, sha, origin = args[0]?, args[1]?, args[2]?
      return refuse("LINK : arguments invalides") unless relative && origin && sha && sha.matches?(SHA_REGEX)
      unless Layout.valid_relative?(relative) && Layout.valid_relative?(origin)
        return refuse("chemin refusé : #{relative}")
      end
      target = File.join(@root, relative)
      return if existing?(target, sha)
      source = File.join(@root, origin)
      return reply("MISSING") unless File.file?(source) && checksum(source) == sha
      if @apply
        FileUtils.mkdir_p(File.dirname(target), 0o700)
        begin
          File.link(source, target)
        rescue File::Error
          FileUtils.cp(source, target)
        end
        write_checksum(target, sha)
      end
      @links += 1
      reply "OK"
    end

    # Fichier déjà présent : `HAVE` s'il est identique, refus sinon
    # (jamais de remplacement). Faux s'il est absent.
    private def existing?(target : String, sha : String) : Bool
      return false unless File.exists?(target) || File.symlink?(target)
      if File.file?(target) && checksum(target) == sha
        reply "HAVE"
      else
        refuse("#{Path[target].relative_to(@root)} existe déjà avec un autre contenu (jamais remplacé)")
      end
      true
    end

    # Lit `size` octets dans un `.part` (ou nulle part en dry-run) ; le
    # fichier n'est mis en place que si leur empreinte est celle annoncée.
    private def store(target : String, size : Int64, sha : String) : Bool
      digest = Digest::SHA256.new
      unless @apply
        copy(size, digest, nil)
        return digest.final.hexstring == sha
      end
      FileUtils.mkdir_p(File.dirname(target), 0o700)
      part = "#{target}.part"
      begin
        File.open(part, "w", perm: 0o600) { |file| copy(size, digest, file) }
        return false unless digest.final.hexstring == sha
        File.rename(part, target)
        write_checksum(target, sha)
        true
      ensure
        File.delete?(part)
      end
    end

    private def copy(size : Int64, digest : Digest::SHA256, file : File?) : Nil
      buffer = Bytes.new(64 * 1024)
      remaining = size
      while remaining > 0
        n = @input.read(buffer[0, Math.min(buffer.size.to_i64, remaining).to_i])
        raise ProtocolError.new("flux interrompu (#{remaining} octet(s) manquant(s))") if n.zero?
        digest.update(buffer[0, n])
        file.try &.write(buffer[0, n])
        remaining -= n
      end
    end

    # Empreinte d'un fichier reçu : celle de son `.sha256` si elle est
    # bien formée, sinon recalculée.
    private def checksum(path : String) : String
      recorded = File.read("#{path}.sha256").split(' ', 2).first rescue nil
      recorded && recorded.matches?(SHA_REGEX) ? recorded : Archiver.sha256(path)
    end

    private def write_checksum(path : String, hex : String) : Nil
      File.write("#{path}.sha256", "#{hex}  #{File.basename(path)}\n", perm: 0o600)
    end

    private def read_line : String?
      @input.gets('\n', MAX_LINE, chomp: true)
    end

    private def reply(message : String) : Nil
      @output.puts message
      @output.flush
    end

    # Répond `ERR` ; rend `false` pour s'enchaîner dans une garde.
    private def refuse(message : String) : Bool
      reply "ERR #{message.gsub('\n', ' ')}"
      false
    end

    # Même verrou que `backup`/`prune` : pas de rotation pendant une
    # réception.
    private def with_lock(&)
      path = Layout.new(@root).lock_path
      File.open(path, "a", perm: 0o600) do |file|
        begin
          file.flock_exclusive(blocking: false)
        rescue IO::Error
          raise LockError.new("verrou #{path} tenu par une autre exécution de jawas")
        end
        begin
          yield
        ensure
          file.flock_unlock
        end
      end
    end
  end
end
