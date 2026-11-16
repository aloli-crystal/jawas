require "./spec_helper"

describe Jawas::Compressor do
  it "construit les arguments zstd avec niveau et threads" do
    c = Jawas::Compressor.new("zstd", 12, 4)
    c.binary.should eq("zstd")
    c.extension.should eq(".zst")
    c.compress_args.should eq(["-c", "-q", "-12", "-T4"])
  end

  it "utilise -p pour les threads de pigz et ignore ceux de gzip" do
    Jawas::Compressor.new("pigz", 9, 8).compress_args.should eq(["-c", "-9", "-p", "8"])
    Jawas::Compressor.new("gzip", 9, 8).compress_args.should eq(["-c", "-9"])
  end

  it "n'a ni binaire ni extension pour none" do
    c = Jawas::Compressor.new("none")
    c.binary.should be_nil
    c.extension.should eq("")
    c.none?.should be_true
  end

  it "refuse un outil inconnu ou un niveau hors plage" do
    expect_raises(Jawas::ConfigError, /inconnu/) { Jawas::Compressor.new("rar") }
    expect_raises(Jawas::ConfigError, /niveau 20/) { Jawas::Compressor.new("zstd", 20) }
    expect_raises(Jawas::ConfigError, /niveau 0/) { Jawas::Compressor.new("gzip", 0) }
  end

  it "retrouve l'outil d'après l'extension" do
    Jawas::Compressor.for_path("a.sql.zst").tool.should eq("zstd")
    Jawas::Compressor.for_path("a.sql.bz2").tool.should eq("bzip2")
    Jawas::Compressor.for_path("a.sql").tool.should eq("none")
  end
end
