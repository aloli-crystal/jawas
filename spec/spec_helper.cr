require "spec"
require "file_utils"
require "../src/jawas"

module SpecHelper
  # Répertoire de travail isolé, supprimé après le bloc.
  def self.with_tmpdir(&)
    dir = File.join(Dir.tempdir, "jawas-spec-#{Random::Secure.hex(6)}")
    Dir.mkdir_p(dir)
    begin
      yield dir
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  def self.config(toml : String) : Jawas::Config
    Jawas::Config.parse(toml)
  end
end
