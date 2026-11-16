# CLI `jawas`.
#
# Conventions UX ALOLI :
#
# * `jawas help [<sous-commande>]`, `-h`, `--help` ;
# * chaque sous-commande et chaque flag long a un raccourci ;
# * les commandes qui modifient (`backup`, `prune`) sont en dry-run par
#   défaut et n'agissent qu'avec `--apply`.
#
# Codes de sortie : 0 succès, 1 erreur d'usage ou de configuration,
# 2 sauvegarde partielle (au moins une base en échec), 3 verrou tenu.

require "option_parser"
require "./jawas"

module Jawas::CLI
  SUBCOMMANDS = {
    "backup" => "b",
    "prune"  => "p",
    "list"   => "l",
    "check"  => "c",
    "sample" => "s",
    "help"   => "h",
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
  end

  def self.parser(options : Options) : OptionParser
    OptionParser.new do |op|
      op.banner = <<-BANNER
        Usage : jawas SOUS-COMMANDE [options]

        Sous-commandes :
          backup (b)   Sauvegarde les bases puis applique la rotation (dry-run sans --apply)
          prune  (p)   Applique seule la rotation (dry-run sans --apply)
          list   (l)   Liste les sauvegardes présentes dans le stockage
          check  (c)   Vérifie la configuration, les outils et les connexions
          sample (s)   Affiche un modèle de configuration TOML
          help   (h)   Affiche l'aide (globale ou d'une sous-commande)

        Options :
        BANNER

      op.on("-c CHEMIN", "--config=CHEMIN", "Fichier de configuration TOML") { |v| options.config = v }
      op.on("-U", "--no-user-config", "Ignore ${XDG_CONFIG_HOME}/jawas/config.toml") { options.no_user_config = true }
      op.on("-a", "--apply", "Exécute réellement (sinon : dry-run)") { options.apply = true }
      op.on("-s NOM", "--source=NOM", "Limite à une source (répétable, ou liste a,b)") do |v|
        options.sources.concat(v.split(',').map(&.strip).reject(&.empty?))
      end
      op.on("-d BASE", "--database=BASE", "Limite à une base (répétable, ou liste a,b)") do |v|
        options.databases.concat(v.split(',').map(&.strip).reject(&.empty?))
      end
      op.on("-P", "--no-prune", "backup : ne pas appliquer la rotation") { options.prune = false }
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
    when "help"   then help(parser, positional[1]?)
    when "sample" then (puts SAMPLE_CONFIG; 0)
    when nil
      STDERR.puts "Erreur : sous-commande inconnue « #{positional.first} »"
      STDERR.puts parser
      1
    else
      config = Config.load(Config.locate(options.config, options.no_user_config?))
      log = options.quiet? ? IO::Memory.new : STDERR
      runner = Runner.new(config, options.sources, options.databases, log)
      case sub
      when "backup" then Commands.backup(runner, options)
      when "prune"  then Commands.prune(runner, options)
      when "list"   then Commands.list(runner, options)
      else               Commands.check(runner, options)
      end
    end
  rescue ex : ConfigError
    STDERR.puts "Configuration : #{ex.message}"
    1
  rescue ex : LockError
    STDERR.puts ex.message
    3
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
      jawas backup [-a] [-s SOURCE] [-d BASE] [-P] [-j]
        Sans --apply : liste les bases et les fichiers qui seraient écrits ou purgés.
        Avec --apply : dump → compression → fichier 0600 + .sha256, liens weekly/monthly
        et latest, rotation (sauf -P), rapport last-run.json. Exemple cron :
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
    "check" => <<-TXT,
      jawas check [-s SOURCE]
        Vérifie la configuration, les exécutables, le stockage et la connexion à chaque source.
      TXT
    "sample" => "jawas sample > ~/.config/jawas/config.toml\n  Modèle de configuration commenté.",
    "help"   => "jawas help [SOUS-COMMANDE]",
  }
end

require "./jawas/commands"

exit Jawas::CLI.run(ARGV)
