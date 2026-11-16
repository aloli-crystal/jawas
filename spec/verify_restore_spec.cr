require "./spec_helper"

private def sqlite? : Bool
  !Process.find_executable("sqlite3").nil?
end

private def age? : Bool
  !Process.find_executable("age").nil? && !Process.find_executable("age-keygen").nil?
end

private def make_db(path : String, rows : Int32 = 3) : Nil
  values = (1..rows).map { |i| "(#{i})" }.join(",")
  Process.run("sqlite3", [path, "CREATE TABLE t(a); INSERT INTO t VALUES #{values};"])
end

private def count_rows(path : String) : String
  out_io = IO::Memory.new
  Process.run("sqlite3", [path, "SELECT count(*) FROM t"], output: out_io)
  out_io.to_s.strip
end

private def lite_config(dir : String, extra : String = "", format : String = "backup") : Jawas::Config
  SpecHelper.config(<<-TOML)
    [storage]
    dir = "#{dir}/store"
    [compression]
    tool = "gzip"
    #{extra}
    [[source]]
    name = "lite"
    engine = "sqlite"
    format = "#{format}"
    paths = ["#{dir}/app.sqlite3"]
    TOML
end

private def backup(config : Jawas::Config, now : Time = Time.local(2026, 11, 17, 3, 0)) : String
  report = Jawas::Runner.new(config, log: IO::Memory.new).backup(apply: true, now: now)
  report.ok?.should be_true
  report.dumps.first.path || fail("chemin absent")
end

private def verify(config : Jawas::Config, path : String, identity : String? = nil) : Jawas::Verifier::Result
  Jawas::Verifier.new(identity, File.join(config.storage.dir, ".work")).verify(path, "lite", "app", "sqlite")
end

describe Jawas::Verifier do
  it "valide les trois niveaux d'une copie SQLite" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"))
      config = lite_config(dir)
      result = verify(config, backup(config))
      {result.checksum, result.archive, result.content}.should eq({"ok", "ok", "ok"})
      result.complete?.should be_true
    end
  end

  it "détecte une empreinte différente" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"))
      config = lite_config(dir)
      path = backup(config)
      File.open(path, "r+") { |file| file.seek(20); file.write_byte(0_u8) }
      result = verify(config, path)
      result.checksum.should eq("échec")
      result.ok?.should be_false
    end
  end

  it "signale un .sha256 absent" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"))
      config = lite_config(dir)
      path = backup(config)
      File.delete("#{path}.sha256")
      verify(config, path).detail.to_s.should contain("absent")
    end
  end

  it "détecte un dump SQL tronqué (contenu)" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      config = lite_config(dir, format: "sql")
      layout = Jawas::Layout.new(config.storage.dir)
      path = layout.file_path("lite", Jawas::Period::Daily, "app", Time.local(2026, 11, 17, 3, 0), ".sql")
      Dir.mkdir_p(File.dirname(path))
      File.write(path, "BEGIN TRANSACTION;\nCREATE TABLE t(a);\n")
      File.write("#{path}.sha256", "#{Jawas::Archiver.sha256(path)}  #{File.basename(path)}\n")
      result = verify(config, path)
      {result.checksum, result.archive, result.content}.should eq({"ok", "ok", "échec"})
    end
  end

  it "contrôle partiellement une sauvegarde chiffrée sans identité, entièrement avec" do
    pending! "age ou sqlite3 absent" unless age? && sqlite?
    SpecHelper.with_tmpdir do |dir|
      key = File.join(dir, "key.txt")
      Process.run("age-keygen", ["-o", key], error: Process::Redirect::Close)
      public_key = IO::Memory.new
      Process.run("age-keygen", ["-y", key], output: public_key)
      make_db(File.join(dir, "app.sqlite3"))
      config = lite_config(dir, %([encryption]\nrecipients = ["#{public_key.to_s.strip}"]))
      path = backup(config)

      partial = verify(config, path)
      partial.ok?.should be_true
      partial.complete?.should be_false
      partial.archive.should eq("ignoré")

      verify(config, path, key).complete?.should be_true
    end
  end
end

describe Jawas::Restorer do
  it "restaure par défaut dans un fichier jetable voisin" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"), 4)
      config = lite_config(dir)
      backup(config)
      restorer = Jawas::Restorer.new(config, log: IO::Memory.new)
      plan = restorer.plan(nil, "app")
      plan.target.should eq(File.join(dir, "app.r202611170300.sqlite3"))
      plan.exists?.should be_false
      plan.original?.should be_false
      restorer.run(plan)
      count_rows(plan.target).should eq("4")
    end
  end

  it "restaure un dump SQL SQLite" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"), 2)
      config = lite_config(dir, format: "sql")
      backup(config)
      restorer = Jawas::Restorer.new(config, log: IO::Memory.new)
      plan = restorer.plan("lite", "app", into: File.join(dir, "copie.sqlite3"))
      restorer.run(plan)
      count_rows(plan.target).should eq("2")
    end
  end

  it "refuse d'écraser une cible existante sans replace, l'accepte avec" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      original = File.join(dir, "app.sqlite3")
      make_db(original, 5)
      config = lite_config(dir)
      backup(config)
      Process.run("sqlite3", [original, "DELETE FROM t"])
      restorer = Jawas::Restorer.new(config, log: IO::Memory.new)
      expect_raises(Jawas::UsageError, /existe déjà/) { restorer.plan(nil, "app", into: original) }
      plan = restorer.plan(nil, "app", into: original, replace: true)
      plan.original?.should be_true
      plan.atomic?.should be_true
      restorer.run(plan)
      count_rows(original).should eq("5")
    end
  end

  it "choisit la sauvegarde par date ou par fichier" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"))
      config = lite_config(dir)
      first = backup(config, Time.local(2026, 11, 15, 3, 0))
      backup(config, Time.local(2026, 11, 16, 3, 0))
      restorer = Jawas::Restorer.new(config, log: IO::Memory.new)
      restorer.plan(nil, "app").path.should contain("2026-11-16")
      restorer.plan(nil, "app", date: Time.local(2026, 11, 15)).path.should eq(first)
      restorer.plan(nil, nil, file: first).path.should eq(first)
      expect_raises(Jawas::UsageError, /aucune sauvegarde/) { restorer.plan(nil, "app", date: Time.local(2026, 1, 1)) }
      expect_raises(Jawas::UsageError, /--database/) { restorer.plan(nil, nil) }
    end
  end

  it "refuse une sauvegarde altérée" do
    pending! "sqlite3 absent" unless sqlite?
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"))
      config = lite_config(dir)
      path = backup(config)
      File.open(path, "r+") { |file| file.seek(20); file.write_byte(0_u8) }
      restorer = Jawas::Restorer.new(config, log: IO::Memory.new)
      plan = restorer.plan(nil, "app")
      expect_raises(Jawas::DumpError, /empreinte/) { restorer.run(plan) }
      File.exists?(plan.target).should be_false
    end
  end

  it "exige l'identité pour une sauvegarde chiffrée dès le plan" do
    SpecHelper.with_tmpdir do |dir|
      config = lite_config(dir, %([encryption]\nrecipients = ["age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"]))
      layout = Jawas::Layout.new(config.storage.dir)
      path = layout.file_path("lite", Jawas::Period::Daily, "app", Time.local(2026, 11, 17, 3, 0), ".sqlite3.gz.age")
      Dir.mkdir_p(File.dirname(path))
      File.write(path, "age-encryption.org/v1\n")
      expect_raises(Jawas::UsageError, /identity/) { Jawas::Restorer.new(config).plan(nil, "app") }
    end
  end

  it "refuse de rejouer _globals" do
    SpecHelper.with_tmpdir do |dir|
      config = SpecHelper.config(<<-TOML)
        [storage]
        dir = "#{dir}/store"
        [[source]]
        name = "pg"
        engine = "postgresql"
        TOML
      layout = Jawas::Layout.new(config.storage.dir)
      path = layout.file_path("pg", Jawas::Period::Daily, "_globals", Time.local(2026, 11, 17, 3, 0), ".sql.gz")
      Dir.mkdir_p(File.dirname(path))
      File.write(path, "x")
      expect_raises(Jawas::UsageError, /_globals/) { Jawas::Restorer.new(config).plan(nil, "_globals") }
    end
  end
end

describe Jawas::Sources::MySQL do
  it "retire CREATE DATABASE et USE de l'en-tête du dump" do
    dump = <<-SQL
      -- MariaDB dump
      CREATE DATABASE /*!32312 IF NOT EXISTS*/ `app` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;
      USE `app`;
      DROP TABLE IF EXISTS `t`;
      CREATE TABLE `t` (`a` int);
      INSERT INTO `t` VALUES (1);
      -- USE `app`; reste tel quel après l'en-tête
      SQL
    output = IO::Memory.new
    Jawas::Sources::MySQL.strip_database_header(IO::Memory.new(dump), output)
    output.to_s.should_not contain("CREATE DATABASE")
    output.to_s.lines.first.should eq("-- MariaDB dump")
    output.to_s.should contain("DROP TABLE IF EXISTS `t`;\nCREATE TABLE")
    output.to_s.should contain("-- USE `app`; reste tel quel")
  end
end

describe Jawas::Source do
  it "résume la sortie d'erreur d'un outil" do
    Jawas::Source.error_summary("--------------\nCECI\n--------------\n\nERROR 1064 (42000) at line 3: syntax\n")
      .should eq("ERROR 1064 (42000) at line 3: syntax")
    Jawas::Source.error_summary("a\nb\nc\nd\n").should eq("b / c / d")
  end
end

describe Jawas::Decoder do
  it "retrouve le format sous compression et chiffrement" do
    Jawas::Decoder.new("/x/app_2026-11-17_03h00.daily.pgdump.zst.age").plain_name
      .should eq("app_2026-11-17_03h00.daily.pgdump")
    Jawas::Decoder.new("/x/app_2026-11-17_03h00.daily.sql").plain_name
      .should eq("app_2026-11-17_03h00.daily.sql")
  end
end
