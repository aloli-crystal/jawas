# CLI `jawas`.
#
# Conventions UX ALOLI :
#
# * `jawas help [<sous-commande>]`, `-h`, `--help` ;
# * chaque sous-commande et chaque flag long a un raccourci ;
# * les commandes qui modifient (`backup`, `prune`, `upload`, `restore`,
#   `receive`) sont en dry-run par défaut et n'agissent qu'avec `--apply`.
#
# Codes de sortie : 0 succès, 1 erreur d'usage ou de configuration,
# 2 échec partiel (au moins une base ou un envoi en échec), 3 verrou tenu.

require "option_parser"
require "./jawas"

module Jawas::CLI
  SUBCOMMANDS = {
    "backup"  => "b",
    "prune"   => "p",
    "list"    => "l",
    "verify"  => "v",
    "restore" => "r",
    "upload"  => "u",
    "receive" => "rx",
    "check"   => "c",
    "sample"  => "s",
    "help"    => "h",
  }

  class Options
    property config : String? = nil
    property? no_user_config = false
    property? apply = false
    property? prune = true
    property? json = false
    property? quiet = false
    property sources = [] of String
    property databases = [] of String
    property identity : String? = nil
    property? all = false
    property date : Time? = nil
    property file : String? = nil
    property into : String? = nil
    property? replace = false
    property? upload = true
    property storage : String? = nil
    property remotes = [] of String
  end

  def self.parser(options : Options) : OptionParser
    OptionParser.new do |op|
      op.banner = <<-BANNER
        Usage : jawas SOUS-COMMANDE [options]

        Sous-commandes :
          backup (b)   Sauvegarde les bases puis applique la rotation (dry-run sans --apply)
          prune  (p)   Applique seule la rotation (dry-run sans --apply)
          list    (l)  Liste les sauvegardes présentes dans le stockage
          verify  (v)  Contrôle empreinte, archive et contenu des sauvegardes
          restore (r)  Restaure une sauvegarde (base jetable par défaut ; dry-run sans --apply)
          upload  (u)  Envoie les sauvegardes vers les [[remote]] (dry-run sans --apply)
          receive (rx) Récepteur d'envoi ssh, en ajout seul (commande forcée côté distant)
          check  (c)   Vérifie la configuration, les outils et les connexions
          sample (s)   Affiche un modèle de configuration TOML
          help   (h)   Affiche l'aide (globale ou d'une sous-commande)

        Options :
        BANNER

      op.on("-c CHEMIN", "--config=CHEMIN", "Fichier de configuration TOML") { |v| options.config = v }
      op.on("-U", "--no-user-config", "Ignore ${XDG_CONFIG_HOME}/jawas/config.toml") { options.no_user_config = true }
      op.on("-S DOSSIER", "--storage=DOSSIER", "Répertoire de stockage (remplace [storage] dir)") { |v| options.storage = v }
      op.on("-a", "--apply", "Exécute réellement (sinon : dry-run)") { options.apply = true }
      op.on("-s NOM", "--source=NOM", "Limite à une source (répétable, ou liste a,b)") do |v|
        options.sources.concat(v.split(',').map(&.strip).reject(&.empty?))
      end
      op.on("-d BASE", "--database=BASE", "Limite à une base (répétable, ou liste a,b)") do |v|
        options.databases.concat(v.split(',').map(&.strip).reject(&.empty?))
      end
      op.on("-i FICHIER", "--identity=FICHIER", "verify/restore : clé privée age des sauvegardes chiffrées") do |v|
        options.identity = v
      end
      op.on("-A", "--all", "verify : toutes les sauvegardes (sinon la dernière de chaque base)") { options.all = true }
      op.on("-D DATE", "--date=DATE", "restore : dernière sauvegarde du jour AAAA-MM-JJ") do |v|
        options.date = Time.parse(v, "%Y-%m-%d", Time::Location.local)
      rescue Time::Format::Error
        STDERR.puts "Date invalide : #{v} (AAAA-MM-JJ attendu)"
        exit 1
      end
      op.on("-f CHEMIN", "--file=CHEMIN", "restore : fichier de sauvegarde précis") { |v| options.file = v }
      op.on("-t CIBLE", "--into=CIBLE", "restore : base (ou fichier SQLite) cible") { |v| options.into = v }
      op.on("-R", "--replace", "restore : écrase la cible si elle existe") { options.replace = true }
      op.on("-P", "--no-prune", "backup : ne pas appliquer la rotation") { options.prune = false }
      op.on("-N", "--no-upload", "backup : ne pas envoyer vers les [[remote]]") { options.upload = false }
      op.on("-r NOM", "--remote=NOM", "Limite à une destination [[remote]] (répétable, ou liste a,b)") do |v|
        options.remotes.concat(v.split(',').map(&.strip).reject(&.empty?))
      end
      op.on("-j", "--json", "Sortie JSON") { options.json = true }
      op.on("-q", "--quiet", "N'affiche que les erreurs") { options.quiet = true }
      op.on("-v", "--version", "Affiche la version") do
        puts "jawas #{Jawas::VERSION}"
        exit 0
      end
      op.on("-h", "--help", "Affiche cette aide") do
        puts op
        exit 0
      end
      op.invalid_option do |flag|
        STDERR.puts "Option inconnue : #{flag}"
        STDERR.puts op
        exit 1
      end
      op.missing_option do |flag|
        STDERR.puts "Valeur manquante pour #{flag}"
        exit 1
      end
    end
  end

  def self.resolve(name : String) : String?
    SUBCOMMANDS.each { |long, short| return long if name == long || name == short }
    name == "ls" ? "list" : nil
  end

  def self.run(argv : Array(String)) : Int32
    options = Options.new
    parser = parser(options)
    positional = [] of String
    parser.unknown_args { |args| positional = args }
    parser.parse(argv)

    if positional.empty?
      STDERR.puts "Erreur : aucune sous-commande spécifiée"
      STDERR.puts parser
      return 1
    end

    case sub = resolve(positional.first)
    when "help"    then help(parser, positional[1]?)
    when "sample"  then (puts SAMPLE_CONFIG; 0)
    when "receive" then Commands.receive(options)
    when nil
      STDERR.puts "Erreur : sous-commande inconnue « #{positional.first} »"
      STDERR.puts parser
      1
    else
      dispatch(sub, options)
    end
  rescue ex : ConfigError
    STDERR.puts "Configuration : #{ex.message}"
    1
  rescue ex : UsageError
    STDERR.puts "Erreur : #{ex.message}"
    1
  rescue ex : LockError
    STDERR.puts ex.message
    3
  rescue ex : File::Error
    # Filet de sécurité : aucune erreur de fichier ne doit finir en
    # « Unhandled exception » (stockage, configuration, secrets…).
    STDERR.puts "Erreur : #{Access.describe(ex)}"
    1
  rescue ex : IO::Error
    STDERR.puts "Erreur d'entrée-sortie : #{ex.message}"
    1
  end

  def self.dispatch(sub : String, options : Options) : Int32
    config = load_config(options)
    log = options.quiet? ? IO::Memory.new : STDERR
    runner = Runner.new(config, options.sources, options.databases, log, options.remotes)
    case sub
    when "backup"  then Commands.backup(runner, options)
    when "prune"   then Commands.prune(runner, options)
    when "list"    then Commands.list(runner, options)
    when "verify"  then Commands.verify(runner, options)
    when "restore" then Commands.restore(runner, options)
    when "upload"  then Commands.upload(runner, options)
    else                Commands.check(runner, options)
    end
  end

  # `--storage` remplace le répertoire du fichier ; sans fichier de
  # configuration, il suffit à recevoir, purger, lister et vérifier.
  def self.load_config(options : Options) : Config
    path = begin
      Config.locate(options.config, options.no_user_config?)
    rescue ex : ConfigError
      raise ex unless (dir = options.storage) && options.config.nil?
      return Config.minimal(dir)
    end
    config = Config.load(path)
    options.storage.try { |dir| config.storage = Config::Storage.new(dir, config.storage.latest) }
    config
  end

  def self.help(parser : OptionParser, sub : String?) : Int32
    if sub.nil? || sub.empty?
      puts parser
      return 0
    end
    unless long = resolve(sub.downcase)
      STDERR.puts "Aide indisponible pour « #{sub} » (sous-commandes : #{SUBCOMMANDS.keys.join(", ")})."
      STDERR.puts "Utilisez `jawas help` pour l'aide globale."
      return 1
    end
    puts parser
    puts ""
    puts "─── Focus : #{long} ───"
    puts HELP_DETAILS[long]
    0
  end

  HELP_DETAILS = {
    "backup" => <<-TXT,
      jawas backup [-a] [-s SOURCE] [-d BASE] [-P] [-N] [-r DEST] [-j]
        Sans --apply : liste les bases et les fichiers qui seraient écrits ou purgés.
        Avec --apply : dump → compression → fichier 0600 + .sha256, liens weekly/monthly
        et latest, rotation (sauf -P), envoi vers les [[remote]] (sauf -N), rapport
        last-run.json. Exemple cron :
          15 3 * * *  jawas backup --apply --quiet
      TXT
    "prune" => <<-TXT,
      jawas prune [-a] [-s SOURCE] [-j]
        Supprime les sauvegardes plus vieilles que [retention], en gardant toujours
        les keep_min plus récentes de chaque base.
      TXT
    "list" => <<-TXT,
      jawas list [-s SOURCE] [-d BASE] [-j]
        Inventaire du stockage : source, période, base, date, taille, présence du .sha256.
      TXT
    "verify" => <<-TXT,
      jawas verify [-s SOURCE] [-d BASE] [-A] [-i CLÉ] [-j]
        Sans -A : la dernière sauvegarde de chaque base. Trois niveaux : empreinte .sha256,
        archive (déchiffrement si -i, décompression complète), contenu (dump terminé,
        en-tête PGDMP, PRAGMA integrity_check). Sans -i, une sauvegarde chiffrée n'est
        contrôlée que sur son empreinte. Code 2 si un contrôle échoue.
      TXT
    "restore" => <<-TXT,
      jawas restore -d BASE [-s SOURCE] [-f FICHIER | -D AAAA-MM-JJ] [-t CIBLE] [-R] [-i CLÉ] [-a]
        Sans --apply : affiche la sauvegarde choisie et la cible. Par défaut, la dernière
        sauvegarde est chargée dans une base jetable <base>_r<AAAAMMJJHHMM> (SQLite : fichier
        voisin). Écraser une base existante, l'originale comprise, exige -t NOM et -R.
        _globals (rôles PostgreSQL) se rejoue à la main.
      TXT
    "upload" => <<-TXT,
      jawas upload [-a] [-r DEST] [-s SOURCE] [-j]
        Envoie les sauvegardes du stockage vers les [[remote]], en ajout seul : jamais de
        suppression ni de remplacement à distance. ssh : récepteur `jawas receive` (seuls les
        fichiers absents sont transmis, les liens weekly/monthly recréés sans transfert) ;
        rclone : `rclone copy --immutable`. `backup --apply` l'enchaîne de lui-même (sauf -N).
      TXT
    "receive" => <<-TXT,
      jawas receive -S DOSSIER --apply
        Côté distant d'un [[remote]] ssh, en commande forcée de la clé de l'émetteur :
          command="jawas receive -S /srv/jawas/web1 --apply",restrict ssh-ed25519 AAAA…
        Accepte les sauvegardes nouvelles, contrôle leur SHA-256, refuse tout remplacement.
        La rotation distante se fait sur place : jawas prune -S /srv/jawas/web1 --apply.
        Sans --apply : contrôle les données reçues sans rien écrire.
      TXT
    "check" => <<-TXT,
      jawas check [-s SOURCE] [-r DEST]
        Vérifie la configuration, les exécutables, le stockage, la connexion à chaque source
        et aux récepteurs ssh des [[remote]].
      TXT
    "sample" => "jawas sample > ~/.config/jawas/config.toml\n  Modèle de configuration commenté.",
    "help"   => "jawas help [SOUS-COMMANDE]",
  }
end

require "./jawas/commands"

exit Jawas::CLI.run(ARGV)
