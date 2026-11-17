require "./spec_helper"

private STAMP = "2026-11-16_03h00"

# Stockage local fabriqué à la main : une sauvegarde daily, sa copie
# weekly en lien physique, avec leurs `.sha256`.
private def seed_store(root : String, content = "-- dump complet\n") : Nil
  daily = File.join(root, "lite", "daily", "app", "app_#{STAMP}.daily.sql.gz")
  weekly = File.join(root, "lite", "weekly", "app", "app_#{STAMP}.weekly.sql.gz")
  [daily, weekly].each { |path| Dir.mkdir_p(File.dirname(path)) }
  File.write(daily, content)
  File.link(daily, weekly)
  hex = Jawas::Archiver.sha256(daily)
  File.write("#{daily}.sha256", "#{hex}  #{File.basename(daily)}\n")
  File.write("#{weekly}.sha256", "#{hex}  #{File.basename(weekly)}\n")
end

private def remote_config(store : String, extra = "") : Jawas::Config
  SpecHelper.config(<<-TOML + "\n" + extra)
    [storage]
    dir = "#{store}"
    [[remote]]
    name = "coffre"
    type = "ssh"
    host = "backup.example.net"
    user = "jawas"
    TOML
end

# Session émetteur ↔ récepteur dans le même processus, par deux tubes.
private def exchange(local : String, remote_root : String, apply = true) : {Jawas::UploadResult, Int32}
  config = remote_config(local)
  uploader = Jawas::Uploader.new(Jawas::Layout.new(local), config.remotes.first, IO::Memory.new)
  to_receiver_r, to_receiver_w = IO.pipe
  to_sender_r, to_sender_w = IO.pipe
  done = Channel(Int32).new
  spawn do
    code = Jawas::Receiver.new(remote_root, to_receiver_r, to_sender_w, apply).run
    to_sender_w.close
    done.send(code)
  end
  result = Jawas::UploadResult.new("coffre", "ssh", "test", true)
  session = Jawas::Uploader::Session.new(to_sender_r, to_receiver_w)
  begin
    if session.hello == "apply"
      uploader.items(["lite"]).each { |item| session.offer(item, result) }
      session.finish
    else
      result.error = "dry-run"
    end
  ensure
    to_receiver_w.close
  end
  {result, done.receive}
end

describe "Jawas [[remote]]" do
  it "lit une destination ssh et une destination rclone" do
    config = remote_config("/tmp/x", <<-TOML)
      [[remote]]
      name = "s3"
      type = "rclone"
      target = "ovh:bucket/web1"
      periods = ["daily"]
      TOML
    config.sources.should be_empty
    ssh, s3 = config.remotes
    ssh.destination.should eq("jawas@backup.example.net")
    ssh.command.should eq("jawas receive --apply")
    s3.binary.should eq("rclone")
    s3.periods.should eq(["daily"])
  end

  it "refuse un type inconnu, une clé d'un autre type, une période inconnue" do
    expect_raises(Jawas::ConfigError, /inconnu/) { remote_config("/x", "[[remote]]\nname = \"a\"\ntype = \"ftp\"\n") }
    expect_raises(Jawas::ConfigError, /target/) { remote_config("/x", "[[remote]]\nname = \"a\"\ntype = \"ssh\"\nhost = \"h\"\ntarget = \"t\"\n") }
    expect_raises(Jawas::ConfigError, /host/) { remote_config("/x", "[[remote]]\nname = \"a\"\ntype = \"ssh\"\n") }
    expect_raises(Jawas::ConfigError, /yearly/) { remote_config("/x", "[[remote]]\nname = \"a\"\ntype = \"rclone\"\ntarget = \"t\"\nperiods = [\"yearly\"]\n") }
    expect_raises(Jawas::ConfigError, /en double/) { remote_config("/x", "[[remote]]\nname = \"coffre\"\ntype = \"rclone\"\ntarget = \"t\"\n") }
  end

  it "refuse backup sans [[source]]" do
    config = remote_config("/tmp/x")
    expect_raises(Jawas::ConfigError, /aucune source/) { Jawas::Runner.new(config, log: IO::Memory.new).backup(apply: false) }
  end

  it "valide les chemins reçus" do
    Jawas::Layout.valid_relative?("lite/daily/app/app_#{STAMP}.daily.sql.gz").should be_true
    Jawas::Layout.valid_relative?("lite/weekly/app/app_#{STAMP}.daily.sql.gz").should be_false
    Jawas::Layout.valid_relative?("../daily/app/app_#{STAMP}.daily.sql.gz").should be_false
    Jawas::Layout.valid_relative?("lite/daily/app/app_#{STAMP}.daily.sql.gz.sha256").should be_false
    Jawas::Layout.valid_relative?("/lite/daily/app/app_#{STAMP}.daily.sql.gz").should be_false
    Jawas::Layout.valid_relative?("lite/daily/.ssh/app_#{STAMP}.daily.sql.gz").should be_false
    Jawas::Layout.valid_relative?("lite/daily/app/other_#{STAMP}.daily.sql.gz").should be_false
  end

  it "envoie, recrée les liens, puis ne renvoie rien" do
    SpecHelper.with_tmpdir do |dir|
      local, remote = File.join(dir, "local"), File.join(dir, "remote")
      seed_store(local)
      result, code = exchange(local, remote)
      code.should eq(0)
      result.ok?.should be_true
      {result.sent, result.linked, result.present}.should eq({1, 1, 0})
      daily = File.join(remote, "lite", "daily", "app", "app_#{STAMP}.daily.sql.gz")
      weekly = File.join(remote, "lite", "weekly", "app", "app_#{STAMP}.weekly.sql.gz")
      File.read(daily).should eq("-- dump complet\n")
      File.same?(daily, weekly).should be_true
      File.read("#{weekly}.sha256").should contain(File.basename(weekly))
      File.info(daily).permissions.value.should eq(0o600)

      again, _ = exchange(local, remote)
      {again.sent, again.linked, again.present}.should eq({0, 0, 2})
      Jawas::Layout.new(remote).stored_sources.should eq(["lite"])
    end
  end

  it "ne remplace jamais un fichier distant différent" do
    SpecHelper.with_tmpdir do |dir|
      local, remote = File.join(dir, "local"), File.join(dir, "remote")
      seed_store(File.join(dir, "other"), "-- autre contenu\n")
      exchange(File.join(dir, "other"), remote)
      seed_store(local)
      result, code = exchange(local, remote)
      code.should eq(0)
      result.ok?.should be_false
      result.failures.first.should contain("jamais remplacé")
      File.read(File.join(remote, "lite", "daily", "app", "app_#{STAMP}.daily.sql.gz")).should eq("-- autre contenu\n")
    end
  end

  it "refuse une sauvegarde altérée sur le disque local" do
    SpecHelper.with_tmpdir do |dir|
      local, remote = File.join(dir, "local"), File.join(dir, "remote")
      seed_store(local)
      File.write(File.join(local, "lite", "daily", "app", "app_#{STAMP}.daily.sql.gz"), "-- abîmé!\n")
      result, _ = exchange(local, remote)
      result.failures.first.should contain("empreinte différente")
      Dir.glob(File.join(remote, "**", "*.gz*")).should be_empty
    end
  end

  it "n'écrit rien quand le récepteur est en dry-run" do
    SpecHelper.with_tmpdir do |dir|
      local, remote = File.join(dir, "local"), File.join(dir, "remote")
      seed_store(local)
      result, _ = exchange(local, remote, apply: false)
      result.error.should eq("dry-run")
      Dir.exists?(remote).should be_false
    end
  end

  it "construit la commande rclone en ajout seul" do
    config = remote_config("/srv/store", "[[remote]]\nname = \"s3\"\ntype = \"rclone\"\ntarget = \"ovh:b/web1\"\nperiods = [\"daily\"]\nconfig = \"/etc/rclone.conf\"\n")
    args = Jawas::Uploader.new(Jawas::Layout.new("/srv/store"), config.remotes.last).rclone_args(["lite"])
    args[0, 4].should eq(["copy", "/srv/store", "ovh:b/web1", "--immutable"])
    args.should contain("+ /lite/daily/**")
    args.should_not contain("+ /lite/weekly/**")
    args.should_not contain("sync")
    args.last(2).should eq(["--config", "/etc/rclone.conf"])
  end

  it "construit la commande ssh" do
    config = remote_config("/srv/store", "")
    args = Jawas::Uploader.new(Jawas::Layout.new("/srv/store"), config.remotes.first).ssh_args
    args.should eq(["-T", "-o", "BatchMode=yes", "jawas@backup.example.net", "jawas receive --apply"])
  end
end
