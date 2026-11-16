require "./spec_helper"

private def sqlite_config(dir : String, paths : Array(String), tool = "gzip") : Jawas::Config
  SpecHelper.config(<<-TOML)
    [storage]
    dir = "#{dir}/store"
    [schedule]
    weekly_day = 1
    monthly_day = 16
    [compression]
    tool = "#{tool}"
    [[source]]
    name = "lite"
    engine = "sqlite"
    paths = #{paths.to_json}
    TOML
end

private def make_db(path : String) : Nil
  Process.run("sqlite3", [path, "CREATE TABLE t(a); INSERT INTO t VALUES (1),(2),(3);"])
end

describe Jawas::Runner do
  monday = Time.local(2026, 11, 16, 3, 0) # lundi 16 → daily + weekly + monthly

  it "n'écrit rien en dry-run" do
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"))
      config = sqlite_config(dir, [File.join(dir, "app.sqlite3")])
      report = Jawas::Runner.new(config, log: IO::Memory.new).backup(apply: false, now: monday)
      report.applied?.should be_false
      report.dumps.size.should eq(1)
      report.dumps.first.periods.should eq(%w[daily weekly monthly])
      Dir.exists?(File.join(dir, "store")).should be_false
    end
  end

  it "sauvegarde SQLite, vérifiable et restaurable" do
    pending! "sqlite3 absent" unless Process.find_executable("sqlite3")
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "app.sqlite3"))
      config = sqlite_config(dir, [File.join(dir, "app.sqlite3")])
      report = Jawas::Runner.new(config, log: IO::Memory.new).backup(apply: true, now: monday)
      report.ok?.should be_true
      result = report.dumps.first
      path = result.path || fail("chemin absent")
      path.should end_with("lite/daily/app/app_2026-11-16_03h00.daily.sqlite3.gz")
      (File.info(path).permissions.value & 0o077).should eq(0)

      # somme de contrôle au format sha256sum
      File.read("#{path}.sha256").should eq("#{result.sha256}  #{File.basename(path)}\n")
      # liens physiques weekly/monthly (même inode)
      weekly = File.join(dir, "store/lite/weekly/app/app_2026-11-16_03h00.weekly.sqlite3.gz")
      File.info(weekly).same_file?(File.info(path)).should be_true
      # lien latest
      File.realpath(File.join(dir, "store/lite/latest/app.sqlite3.gz")).should eq(File.realpath(path))
      # restauration
      restored = File.join(dir, "restored.sqlite3")
      File.open(restored, "w") { |file| Process.run("gzip", ["-dc", path], output: file) }
      count = IO::Memory.new
      Process.run("sqlite3", [restored, "SELECT count(*) FROM t"], output: count)
      count.to_s.strip.should eq("3")
      # rapport
      JSON.parse(File.read(File.join(dir, "store/last-run.json")))["dumps"].size.should eq(1)
    end
  end

  it "continue après l'échec d'une base et le signale" do
    pending! "sqlite3 absent" unless Process.find_executable("sqlite3")
    SpecHelper.with_tmpdir do |dir|
      make_db(File.join(dir, "good.sqlite3"))
      config = sqlite_config(dir, [File.join(dir, "missing.sqlite3"), File.join(dir, "good.sqlite3")], "none")
      report = Jawas::Runner.new(config, log: IO::Memory.new).backup(apply: true, now: monday)
      report.ok?.should be_false
      report.dumps.map(&.ok?).should eq([false, true])
      report.dumps.first.error.to_s.should contain("introuvable")
      Dir.glob(File.join(dir, "store/**/*.part")).should be_empty
    end
  end

  it "refuse une source inconnue" do
    SpecHelper.with_tmpdir do |dir|
      config = sqlite_config(dir, ["/x.sqlite3"])
      expect_raises(Jawas::ConfigError, /nope/) { Jawas::Runner.new(config, ["nope"]) }
    end
  end

  it "refuse une exécution concurrente" do
    SpecHelper.with_tmpdir do |dir|
      config = sqlite_config(dir, [File.join(dir, "app.sqlite3")])
      runner = Jawas::Runner.new(config, log: IO::Memory.new)
      Dir.mkdir_p(runner.layout.root)
      File.open(runner.layout.lock_path, "a") do |held|
        held.flock_exclusive
        expect_raises(Jawas::LockError) { runner.prune(apply: true) }
      end
    end
  end
end
