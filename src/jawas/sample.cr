module Jawas
  # Modèle de configuration affiché par `jawas sample`.
  SAMPLE_CONFIG = <<-TOML
    # Configuration jawas — ${XDG_CONFIG_HOME:-~/.config}/jawas/config.toml
    # ou /etc/jawas/config.toml (serveur).

    [storage]
    dir = "/var/backups/jawas"   # créé en 0700, fichiers en 0600
    latest = true                # liens latest/<base>.<ext> vers le dernier dump

    [schedule]
    weekly_day = 6               # 1 = lundi … 7 = dimanche, 0 = pas de weekly
    monthly_day = 1              # 1 … 31 (31 = dernier jour du mois), 0 = pas de monthly

    [retention]                  # en jours ; 0 = jamais purgé
    daily = 7
    weekly = 35
    monthly = 180
    keep_min = 2                 # toujours garder au moins N sauvegardes par base

    [compression]
    tool = "zstd"                # none, gzip, pigz, bzip2, xz, zstd
    level = 6
    threads = 0                  # 0 = automatique (pigz, xz, zstd)

    [hooks]
    pre = []                     # ex. ["systemctl stop app-worker"]
    post = []                    # reçoivent JAWAS_STATUS (ok/failed) et JAWAS_REPORT

    [[source]]
    name = "mysql-local"
    engine = "mariadb"           # mysql, mariadb, postgresql, sqlite
    socket = "/run/mysqld/mysqld.sock"
    user = "backup"
    password_file = "/etc/jawas/mysql.password"   # ou password_env, ou defaults_file
    databases = []               # vide = toutes les bases du serveur
    exclude = ["information_schema", "performance_schema", "sys", "test_*"]
    exclude_tables = ["app.sessions"]
    # single_transaction = true ; routines = true ; events = true
    # extra_args = ["--column-statistics=0"]

    [[source]]
    name = "pg-local"
    engine = "postgresql"
    socket = "/var/run/postgresql"
    user = "postgres"
    format = "plain"             # plain (SQL) ou custom (pg_restore)
    globals = true               # rôles et tablespaces dans la « base » _globals
    # dump_bin = "/usr/lib/postgresql/17/bin/pg_dump"

    [[source]]
    name = "sqlite-apps"
    engine = "sqlite"
    paths = ["/srv/app/db/production.sqlite3"]
    format = "backup"            # backup (copie binaire cohérente) ou sql
    TOML
end
