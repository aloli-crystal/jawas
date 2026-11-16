require "./spec_helper"

describe Jawas::Layout do
  layout = Jawas::Layout.new("/b")
  time = Time.local(2026, 11, 16, 3, 5)

  it "range les fichiers par source, période et base" do
    layout.file_path("srv", Jawas::Period::Weekly, "app", time, ".sql.gz")
      .should eq("/b/srv/weekly/app/app_2026-11-16_03h05.weekly.sql.gz")
  end

  it "assainit les noms de base" do
    Jawas::Layout.safe("ma base/ö").should eq("ma_base__")
    Jawas::Layout.safe(".hidden").should eq("_hidden")
    Jawas::Layout.safe("app-prod_1.x").should eq("app-prod_1.x")
  end

  it "relit la date dans le nom de fichier" do
    Jawas::Layout.backup_time("/x/app_2026-11-16_03h05.daily.sql.gz").should eq(time)
  end

  it "reconnaît les fichiers de sauvegarde" do
    Jawas::Layout.backup_file?("app_2026-11-16_03h05.daily.sql.gz").should be_true
    Jawas::Layout.backup_file?("app_2026-11-16_03h05.daily.sql.gz.sha256").should be_false
    Jawas::Layout.backup_file?("app_2026-11-16_03h05.daily.sql.gz.part").should be_false
    Jawas::Layout.backup_file?("notes.txt").should be_false
  end
end
