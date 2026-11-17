require "system/user"
require "system/group"

lib LibC
  fun geteuid : UidT
end

module Jawas
  # Diagnostic des accès refusés au système de fichiers.
  #
  # Exemple typique : `sudo -u postgres jawas check` avec
  # `[storage] dir = "/var/backups/jawas"` alors que `/var/backups` est
  # `root:wheel 0750` sous FreeBSD. Crystal lève alors
  # `File::AccessDeniedError` dès le premier `stat` ; ce module
  # transforme l'exception en message utile : chemin, utilisateur
  # courant et premier répertoire parent non traversable.
  module Access
    # Nom de l'utilisateur effectif (celui dont les droits comptent).
    def self.user : String
      uid = LibC.geteuid.to_s
      System::User.find_by?(id: uid).try(&.username) || "uid #{uid}"
    end

    # Premier répertoire parent de *path* que l'utilisateur courant ne
    # peut pas traverser (droit `x` absent), ou nil. S'arrête au premier
    # parent absent : un chemin à créer n'est pas bloqué pour autant.
    def self.blocker(path : String | Path) : String?
      Path[path].expand.parents.each do |parent|
        return unless File.exists?(parent)
        return parent.to_s unless File::Info.executable?(parent)
      end
      nil
    rescue File::Error
      nil
    end

    # `propriétaire:groupe mode` d'un chemin, ex. `root:wheel 0750`.
    def self.ownership(path : String) : String?
      info = File.info(path)
      owner = System::User.find_by?(id: info.owner_id).try(&.username) || info.owner_id
      group = System::Group.find_by?(id: info.group_id).try(&.name) || info.group_id
      "#{owner}:#{group} #{info.permissions.value.to_s(8).rjust(4, '0')}"
    rescue File::Error
      nil
    end

    # Message d'accès refusé à *path* pour l'utilisateur courant, avec le
    # répertoire parent fautif s'il y en a un.
    def self.denied(path : String) : String
      text = "accès refusé à #{path} pour l'utilisateur #{user}"
      if parent = blocker(path)
        rights = ownership(parent).try { |value| " (#{value})" }
        "#{text} : le répertoire parent #{parent}#{rights} ne lui est pas accessible " \
        "(droit de traversée x manquant) ; ouvrez-le-lui ou choisissez un autre emplacement"
      elsif rights = ownership(path)
        "#{text} (#{rights})"
      else
        text
      end
    end

    # Message d'une erreur de fichier : diagnostic complet pour un accès
    # refusé, message de Crystal sinon.
    def self.describe(ex : File::Error) : String
      ex.is_a?(File::AccessDeniedError) ? denied(ex.file) : ex.message.to_s
    end

    def self.message(ex : Exception) : String
      ex.is_a?(File::Error) ? describe(ex) : ex.message.to_s
    end

    # Pourquoi *path* n'est pas lisible (sans lever d'exception), ou nil
    # s'il l'est.
    def self.unreadable(path : String) : String?
      return denied(path) if blocker(path)
      return "#{path} introuvable" unless File.exists?(path)
      File::Info.readable?(path) ? nil : denied(path)
    rescue ex : File::Error
      describe(ex)
    end
  end
end
