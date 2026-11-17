module Jawas
  # Étape d'un flux de traitement : un exécutable qui lit stdin et écrit
  # stdout (compresseur, chiffrement).
  record Filter, name : String, binary : String, args : Array(String)

  # Chiffrement des sauvegardes par `age` (https://age-encryption.org).
  #
  # Seules des clés *publiques* sont nécessaires : `age1…` (clé native ou
  # de plugin) et clés SSH `ssh-ed25519` / `ssh-rsa`, données en ligne
  # (`recipients`) ou dans un fichier au format `age -R`
  # (`recipients_file`, une clé par ligne, `#` pour commenter). Le
  # serveur sauvegardé ne détient donc aucun moyen de relire ses
  # propres sauvegardes : la clé privée reste chez l'opérateur.
  #
  # Le chiffrement s'applique après la compression (des données
  # chiffrées ne se compressent plus) et ajoute l'extension `.age`.
  # `rage` (implémentation Rust compatible) convient aussi (`binary`).
  class Encryptor
    EXTENSION = ".age"
    RECIPIENT = /\A(age1[0-9a-z]+|ssh-(ed25519|rsa) [A-Za-z0-9+\/=]+( .*)?)\z/

    getter recipients : Array(String)
    getter recipients_file : String?
    getter binary_name : String

    def initialize(@recipients : Array(String) = [] of String, @recipients_file : String? = nil,
                   @binary_name : String = "age")
      if @recipients.empty? && @recipients_file.nil?
        raise ConfigError.new("[encryption] : `recipients` ou `recipients_file` est obligatoire")
      end
      if @recipients.any?(&.starts_with?("AGE-SECRET-KEY-"))
        raise ConfigError.new("[encryption] : clé PRIVÉE fournie, seule la clé publique (age1…) a sa place ici")
      end
      @recipients.each do |recipient|
        next if recipient.matches?(RECIPIENT)
        raise ConfigError.new("[encryption] : destinataire invalide « #{recipient[0, 20]}… » " \
                              "(clé publique age1…, ssh-ed25519 ou ssh-rsa attendue)")
      end
    end

    def extension : String
      EXTENSION
    end

    def args : Array(String)
      list = ["--encrypt"]
      @recipients.each { |recipient| list << "--recipient" << recipient }
      if file = @recipients_file
        list << "--recipients-file" << file
      end
      list
    end

    def binary : String
      @binary ||= resolve_binary
    end

    @binary : String?

    def filter : Filter
      if (file = @recipients_file) && (problem = Access.unreadable(file))
        raise DumpError.new("[encryption] : recipients_file illisible : #{problem}")
      end
      Filter.new(File.basename(@binary_name), binary, args)
    end

    # Chiffre une entrée vide pour valider l'exécutable et chaque
    # destinataire (`jawas check`). Renvoie le message d'erreur, ou nil.
    def self_test : String?
      err = IO::Memory.new
      status = Process.run(filter.binary, args, input: IO::Memory.new(""),
        output: Process::Redirect::Close, error: err)
      status.success? ? nil : "#{@binary_name} a refusé les destinataires : #{err.to_s.strip}"
    rescue ex : DumpError | File::Error | IO::Error
      Access.message(ex)
    end

    private def resolve_binary : String
      if @binary_name.includes?('/')
        return @binary_name if File::Info.executable?(@binary_name)
        raise DumpError.new("exécutable de chiffrement introuvable : #{@binary_name}")
      end
      Process.find_executable(@binary_name) ||
        raise DumpError.new("exécutable de chiffrement introuvable dans le PATH : #{@binary_name}")
    end
  end
end
