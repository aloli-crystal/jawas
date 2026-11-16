module Jawas
  # Racine de toutes les erreurs levées par jawas.
  class Error < Exception
  end

  # Configuration absente, illisible ou invalide.
  class ConfigError < Error
  end

  # Échec d'un dump (outil absent, code retour non nul, fichier source
  # introuvable…).
  class DumpError < Error
  end

  # Une autre exécution de jawas tient déjà le verrou du répertoire de
  # stockage.
  class LockError < Error
  end
end
