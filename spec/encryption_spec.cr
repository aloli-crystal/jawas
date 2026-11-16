require "./spec_helper"

private def age_available? : Bool
  !Process.find_executable("age").nil? && !Process.find_executable("age-keygen").nil?
end

# Génère une identité age jetable ; renvoie {fichier de clé, clé publique}.
private def age_identity(dir : String) : {String, String}
  key = File.join(dir, "key.txt")
  Process.run("age-keygen", ["-o", key], error: Process::Redirect::Close)
  public_key = IO::Memory.new
  Process.run("age-keygen", ["-y", key], output: public_key)
  {key, public_key.to_s.strip}
end

ENCRYPTION_BASE = <<-TOML + "\n"
  [storage]
  dir = "/b"

  [[source]]
  name = "db1"
  engine = "mysql"
  TOML

describe Jawas::Encryptor do
  it "n'est pas actif sans section [encryption]" do
    SpecHelper.config(ENCRYPTION_BASE).encryptor.should be_nil
  end

  it "lit les destinataires en ligne et par fichier" do
    config = SpecHelper.config(ENCRYPTION_BASE + <<-TOML)
      [encryption]
      recipients = ["age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl ops@example"]
      recipients_file = "/etc/jawas/recipients.txt"
      TOML
    encryptor = config.encryptor || fail("chiffrement absent")
    encryptor.extension.should eq(".age")
    encryptor.args.should eq(["--encrypt",
                              "--recipient", "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p",
                              "--recipient", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl ops@example",
                              "--recipients-file", "/etc/jawas/recipients.txt"])
  end

  it "exige au moins un destinataire" do
    expect_raises(Jawas::ConfigError, /obligatoire/) do
      SpecHelper.config(ENCRYPTION_BASE + "[encryption]\n")
    end
  end

  it "refuse une clé privée à la place de la clé publique" do
    expect_raises(Jawas::ConfigError, /PRIVÉE/) do
      SpecHelper.config(ENCRYPTION_BASE + %([encryption]\nrecipients = ["AGE-SECRET-KEY-1QQQ"]\n))
    end
  end

  it "refuse un destinataire mal formé" do
    expect_raises(Jawas::ConfigError, /destinataire invalide/) do
      SpecHelper.config(ENCRYPTION_BASE + %([encryption]\nrecipients = ["philippe@aloli.fr"]\n))
    end
  end

  it "valide les destinataires auprès d'age (self_test)" do
    pending! "age absent" unless age_available?
    SpecHelper.with_tmpdir do |dir|
      _, public_key = age_identity(dir)
      Jawas::Encryptor.new([public_key]).self_test.should be_nil
      Jawas::Encryptor.new(["age1qqqqqqqqqqqqqqqqqqqq"]).self_test.to_s.should contain("refusé")
    end
  end

  it "retrouve le compresseur d'un fichier chiffré" do
    Jawas::Compressor.for_path("a.sql.zst.age").tool.should eq("zstd")
  end

  it "chiffre une sauvegarde SQLite que seule la clé privée relit" do
    pending! "age ou sqlite3 absent" unless age_available? && Process.find_executable("sqlite3")
    SpecHelper.with_tmpdir do |dir|
      key, public_key = age_identity(dir)
      db = File.join(dir, "app.sqlite3")
      Process.run("sqlite3", [db, "CREATE TABLE t(a); INSERT INTO t VALUES (1),(2);"])
      config = SpecHelper.config(<<-TOML)
        [storage]
        dir = "#{dir}/store"
        [encryption]
        recipients = ["#{public_key}"]
        [[source]]
        name = "lite"
        engine = "sqlite"
        paths = ["#{db}"]
        TOML
      report = Jawas::Runner.new(config, log: IO::Memory.new).backup(apply: true, now: Time.local(2026, 11, 17, 3, 0))
      report.ok?.should be_true
      path = report.dumps.first.path || fail("chemin absent")
      path.should end_with(".sqlite3.gz.age")
      File.read(path).should start_with("age-encryption.org/v1")
      File.read("#{path}.sha256").should start_with(report.dumps.first.sha256.to_s)

      decrypted = File.join(dir, "decrypted.gz")
      Process.run("age", ["-d", "-i", key, "-o", decrypted, path]).success?.should be_true
      restored = File.join(dir, "restored.sqlite3")
      File.open(restored, "w") { |file| Process.run("gzip", ["-dc", decrypted], output: file) }
      count = IO::Memory.new
      Process.run("sqlite3", [restored, "SELECT count(*) FROM t"], output: count)
      count.to_s.strip.should eq("2")
    end
  end

  it "fait échouer la sauvegarde, sans fichier partiel, si age refuse le destinataire" do
    pending! "age ou sqlite3 absent" unless age_available? && Process.find_executable("sqlite3")
    SpecHelper.with_tmpdir do |dir|
      db = File.join(dir, "app.sqlite3")
      Process.run("sqlite3", [db, "CREATE TABLE t(a);"])
      config = SpecHelper.config(<<-TOML)
        [storage]
        dir = "#{dir}/store"
        [compression]
        tool = "zstd"
        [encryption]
        recipients = ["age1qqqqqqqqqqqqqqqqqqqq"]
        [[source]]
        name = "lite"
        engine = "sqlite"
        paths = ["#{db}"]
        TOML
      report = Jawas::Runner.new(config, log: IO::Memory.new).backup(apply: true, prune: false)
      report.ok?.should be_false
      report.dumps.first.error.to_s.should start_with("age a échoué")
      Dir.glob(File.join(dir, "store/**/*.{part,age}")).should be_empty
    end
  end
end
