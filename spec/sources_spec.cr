require "./spec_helper"

describe Jawas::Sources::MySQL do
  it "construit les arguments de mysqldump sans mot de passe en ligne de commande" do
    SpecHelper.with_tmpdir do |dir|
      ENV["JAWAS_SPEC_MYPW"] = "p\"w"
      config = SpecHelper.config(<<-TOML).sources.first
        [storage]
        dir = "#{dir}"
        [[source]]
        name = "m"
        engine = "mysql"
        host = "db.local"
        user = "backup"
        password_env = "JAWAS_SPEC_MYPW"
        exclude_tables = ["app.sessions", "other.logs"]
        TOML
      source = Jawas::Sources::MySQL.new(config, File.join(dir, ".work"))
      args = source.dump_args("app")
      args.first.should start_with("--defaults-extra-file=")
      args.should contain("--single-transaction")
      args.should contain("--ignore-table=app.sessions")
      args.should_not contain("--ignore-table=app.logs")
      args.last(2).should eq(["--databases", "app"])
      args.join(' ').should_not contain("p\"w")

      file = args.first.split('=', 2).last
      (File.info(file).permissions.value & 0o077).should eq(0)
      File.read(file).should contain(%(password="p\\"w"))
      File.read(file).should contain(%(host="db.local"))
      source.close
      File.exists?(file).should be_false
    ensure
      ENV.delete("JAWAS_SPEC_MYPW")
    end
  end
end

describe Jawas::Sources::PostgreSQL do
  it "ajoute _globals et construit les arguments de pg_dump" do
    config = SpecHelper.config(<<-TOML).sources.first
      [storage]
      dir = "/b"
      [[source]]
      name = "p"
      engine = "postgresql"
      databases = ["app"]
      format = "custom"
      port = 5433
      exclude_tables = ["app.audit.*"]
      TOML
    source = Jawas::Sources::PostgreSQL.new(config)
    source.databases.should eq(["_globals", "app"])
    source.extension("app").should eq(".pgdump")
    source.extension("_globals").should eq(".sql")
    args = source.dump_args("app")
    args.should contain("-w")
    args.should contain("--exclude-table=audit.*")
    args.each_cons_pair.to_a.should contain({"-p", "5433"})
    args.last.should eq("--dbname=app")
  end
end
