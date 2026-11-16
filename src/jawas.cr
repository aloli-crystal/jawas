require "./jawas/version"
require "./jawas/error"
require "./jawas/period"
require "./jawas/encryptor"
require "./jawas/compressor"
require "./jawas/config"
require "./jawas/source"
require "./jawas/sources/mysql"
require "./jawas/sources/postgresql"
require "./jawas/sources/sqlite"
require "./jawas/layout"
require "./jawas/result"
require "./jawas/archiver"
require "./jawas/retention"
require "./jawas/runner"
require "./jawas/inventory"
require "./jawas/sample"

# Couteau suisse de sauvegarde : dumps MySQL/MariaDB, PostgreSQL et
# SQLite, rotation quotidienne/hebdomadaire/mensuelle, compresseur au
# choix, configuration TOML. Réinterprétation Crystal d'automysqlbackup.
#
# ```
# require "jawas"
#
# config = Jawas::Config.load("/etc/jawas/config.toml")
# report = Jawas::Runner.new(config).backup(apply: true)
# puts report.ok?
# ```
module Jawas
end
