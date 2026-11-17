require "./spec_helper"

# Accès refusés : `/var/backups` en `root:wheel 0750` sous FreeBSD rend
# `[storage] dir = "/var/backups/jawas"` intraversable pour `postgres`.
# Reproduit avec un répertoire `chmod 000` (sans effet pour root).
module AccessSpec
  def self.root? : Bool
    LibC.geteuid == 0
  end

  # *dir*/locked (0000) contient storage/ ; bloc exécuté verrou posé.
  def self.with_locked_dir(&)
    SpecHelper.with_tmpdir do |dir|
      locked = File.join(dir, "locked")
      Dir.mkdir_p(File.join(locked, "storage"))
      File.write(File.join(locked, "secret"), "x")
      File.chmod(locked, 0o000)
      begin
        yield dir, locked
      ensure
        File.chmod(locked, 0o755)
      end
    end
  end

  CLI_BINARY = File.join(__DIR__, "tmp", "jawas-access-test")

  def self.cli(args : Array(String), input : String = "") : {Int32, String, String}
    output, error = IO::Memory.new, IO::Memory.new
    status = Process.run(CLI_BINARY, args, input: IO::Memory.new(input), output: output, error: error,
      env: {"XDG_CONFIG_HOME" => Dir.tempdir})
    {status.exit_code, output.to_s, error.to_s}
  end
end

describe Jawas::Access do
  it "nomme l'utilisateur effectif" do
    Jawas::Access.user.should_not be_empty
  end

  it "trouve le répertoire parent non traversable" do
    pending! "root traverse tout" if AccessSpec.root?
    AccessSpec.with_locked_dir do |_, locked|
      Jawas::Access.blocker(File.join(locked, "storage")).should eq(locked)
      Jawas::Access.blocker(File.join(locked, "storage", "a", "b")).should eq(locked)
    end
  end

  it "ne voit aucun blocage sur un chemin accessible ou à créer" do
    SpecHelper.with_tmpdir do |dir|
      Jawas::Access.blocker(dir).should be_nil
      Jawas::Access.blocker(File.join(dir, "absent", "storage")).should be_nil
    end
  end

  it "décrit un File::AccessDeniedError : chemin, utilisateur, parent fautif et ses droits" do
    pending! "root traverse tout" if AccessSpec.root?
    AccessSpec.with_locked_dir do |_, locked|
      path = File.join(locked, "storage")
      error = expect_raises(File::AccessDeniedError) { Dir.exists?(path) }
      message = Jawas::Access.describe(error)
      message.should contain(path)
      message.should contain("l'utilisateur #{Jawas::Access.user}")
      message.should contain("le répertoire parent #{locked}")
      message.should contain(" 0000)")
    end
  end

  it "explique pourquoi un fichier n'est pas lisible, sans lever" do
    pending! "root lit tout" if AccessSpec.root?
    AccessSpec.with_locked_dir do |dir, locked|
      Jawas::Access.unreadable(File.join(locked, "secret")).to_s.should contain("accès refusé")
      Jawas::Access.unreadable(File.join(dir, "absent")).should eq("#{File.join(dir, "absent")} introuvable")
      File.write(File.join(dir, "ok"), "x")
      Jawas::Access.unreadable(File.join(dir, "ok")).should be_nil
    end
  end

  it "password_file dans un répertoire fermé : ConfigError explicite" do
    pending! "root lit tout" if AccessSpec.root?
    AccessSpec.with_locked_dir do |_, locked|
      file = File.join(locked, "secret")
      source = Jawas::Config::SourceConfig.new("db", "postgresql", password_file: file)
      error = expect_raises(Jawas::ConfigError) { source.password }
      error.message.to_s.should contain("le répertoire parent #{locked}")
    end
  end

  it "recipients_file dans un répertoire fermé : DumpError explicite" do
    pending! "root lit tout" if AccessSpec.root?
    AccessSpec.with_locked_dir do |_, locked|
      encryptor = Jawas::Encryptor.new(recipients_file: File.join(locked, "secret"))
      error = expect_raises(Jawas::DumpError) { encryptor.filter }
      error.message.to_s.should contain("le répertoire parent #{locked}")
    end
  end

  it "--config inaccessible : ConfigError, emplacement implicite inaccessible : passé" do
    pending! "root traverse tout" if AccessSpec.root?
    AccessSpec.with_locked_dir do |_, locked|
      error = expect_raises(Jawas::ConfigError) { Jawas::Config.locate(File.join(locked, "config.toml")) }
      error.message.to_s.should contain("le répertoire parent #{locked}")
      previous = ENV["XDG_CONFIG_HOME"]?
      ENV["XDG_CONFIG_HOME"] = locked
      begin
        located = Jawas::Config.locate(nil) rescue nil
        located.should_not eq(File.join(locked, "jawas", "config.toml"))
      ensure
        previous ? (ENV["XDG_CONFIG_HOME"] = previous) : ENV.delete("XDG_CONFIG_HOME")
      end
    end
  end
end

describe "jawas, stockage inaccessible" do
  before_all do
    Dir.mkdir_p(File.dirname(AccessSpec::CLI_BINARY))
    Process.run("crystal", ["build", File.join(__DIR__, "..", "src", "cli.cr"), "-o", AccessSpec::CLI_BINARY],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
  end

  after_all do
    File.delete?(AccessSpec::CLI_BINARY)
  end

  it "`check` liste le stockage en échec au lieu de planter" do
    pending! "root traverse tout" if AccessSpec.root?
    pending! "binaire CLI absent" unless File.exists?(AccessSpec::CLI_BINARY)
    AccessSpec.with_locked_dir do |_, locked|
      storage = File.join(locked, "storage")
      code, output, error = AccessSpec.cli(["check", "-U", "-S", storage])
      code.should eq(1)
      error.should_not contain("Unhandled exception")
      output.should contain("✗ stockage #{storage} — accès refusé")
      output.should contain("le répertoire parent #{locked}")
      output.should contain("✗ 1 problème(s)")
    end
  end

  it "`receive` renvoie la raison à l'émetteur" do
    pending! "root traverse tout" if AccessSpec.root?
    pending! "binaire CLI absent" unless File.exists?(AccessSpec::CLI_BINARY)
    AccessSpec.with_locked_dir do |_, locked|
      storage = File.join(locked, "storage")
      code, output, error = AccessSpec.cli(["receive", "-U", "-S", storage, "--apply"], "JAWAS-RECEIVE 1\n")
      code.should eq(1)
      error.should_not contain("Unhandled exception")
      output.should contain("ERR accès refusé")
      output.should contain("le répertoire parent #{locked}")
    end
  end

  it "list, verify et prune : message clair et code non nul" do
    pending! "root traverse tout" if AccessSpec.root?
    pending! "binaire CLI absent" unless File.exists?(AccessSpec::CLI_BINARY)
    AccessSpec.with_locked_dir do |_, locked|
      storage = File.join(locked, "storage")
      [%w[list], %w[verify], %w[prune --apply]].each do |args|
        code, _, error = AccessSpec.cli(args + ["-U", "-S", storage])
        code.should eq(1)
        error.should_not contain("Unhandled exception")
        error.should contain("Erreur : accès refusé")
        error.should contain("pour l'utilisateur #{Jawas::Access.user}")
        error.should contain("le répertoire parent #{locked}")
      end
    end
  end
end
