require "./spec_helper"

MINIMAL = <<-TOML + "\n"
  [storage]
  dir = "/var/backups/jawas"

  [[source]]
  name = "db1"
  engine = "mysql"
  TOML

describe Jawas::Config do
  it "applique les valeurs par défaut" do
    config = SpecHelper.config(MINIMAL)
    config.storage.dir.should eq("/var/backups/jawas")
    config.storage.latest.should be_true
    config.schedule.weekly_day.should eq(6)
    config.schedule.monthly_day.should eq(1)
    config.retention.daily.should eq(7)
    config.retention.keep_min.should eq(2)
    config.compressor.tool.should eq("gzip")
    source = config.sources.first
    source.exclude.should contain("information_schema")
    source.single_transaction?.should be_true
  end

  it "lit le modèle `jawas sample` sans erreur" do
    config = SpecHelper.config(Jawas::SAMPLE_CONFIG)
    config.sources.map(&.engine).should eq(%w[mariadb postgresql sqlite])
    config.compressor.tool.should eq("zstd")
    config.sources.last.databases.should eq(["/srv/app/db/production.sqlite3"])
  end

  it "refuse une clé inconnue (faute de frappe)" do
    expect_raises(Jawas::ConfigError, /retention.dayly/) do
      SpecHelper.config(MINIMAL + "\n[retention]\ndayly = 3\n")
    end
  end

  it "refuse un mot de passe en clair" do
    expect_raises(Jawas::ConfigError, /password/) do
      SpecHelper.config(MINIMAL + "password = \"secret\"\n")
    end
  end

  it "refuse un moteur inconnu" do
    expect_raises(Jawas::ConfigError, /oracle/) do
      SpecHelper.config(MINIMAL.sub("mysql", "oracle"))
    end
  end

  it "refuse un type incorrect en nommant la clé" do
    expect_raises(Jawas::ConfigError, /schedule.weekly_day doit être un entier/) do
      SpecHelper.config(MINIMAL + "\n[schedule]\nweekly_day = \"vendredi\"\n")
    end
  end

  it "refuse les noms de source en double" do
    expect_raises(Jawas::ConfigError, /double/) do
      SpecHelper.config(MINIMAL + "\n[[source]]\nname = \"db1\"\nengine = \"postgresql\"\n")
    end
  end

  it "exige `paths` pour SQLite" do
    expect_raises(Jawas::ConfigError, /paths/) do
      SpecHelper.config(MINIMAL.sub("mysql", "sqlite"))
    end
  end

  it "refuse password_env et password_file ensemble" do
    expect_raises(Jawas::ConfigError, /exclusifs/) do
      SpecHelper.config(MINIMAL + "password_env = \"A\"\npassword_file = \"/x\"\n")
    end
  end

  it "résout le mot de passe depuis l'environnement" do
    ENV["JAWAS_SPEC_PW"] = "s3cr\"et"
    config = SpecHelper.config(MINIMAL + "password_env = \"JAWAS_SPEC_PW\"\n")
    config.sources.first.password.should eq("s3cr\"et")
  ensure
    ENV.delete("JAWAS_SPEC_PW")
  end

  it "signale un TOML invalide" do
    expect_raises(Jawas::ConfigError, /TOML invalide/) { SpecHelper.config("[storage\n") }
  end

  describe ".locate" do
    it "préfère la configuration XDG de l'utilisateur" do
      SpecHelper.with_tmpdir do |dir|
        old = ENV["XDG_CONFIG_HOME"]?
        ENV["XDG_CONFIG_HOME"] = dir
        begin
          Dir.mkdir_p(File.join(dir, "jawas"))
          path = File.join(dir, "jawas", "config.toml")
          File.write(path, MINIMAL)
          Jawas::Config.locate(nil).should eq(path)
          begin
            Jawas::Config.locate(nil, no_user_config: true).should_not eq(path)
          rescue Jawas::ConfigError
            # aucune configuration système sur cette machine : attendu
          end
        ensure
          old ? (ENV["XDG_CONFIG_HOME"] = old) : ENV.delete("XDG_CONFIG_HOME")
        end
      end
    end

    it "échoue si le fichier explicite est absent" do
      expect_raises(Jawas::ConfigError, /introuvable/) { Jawas::Config.locate("/nonexistent.toml") }
    end
  end
end
