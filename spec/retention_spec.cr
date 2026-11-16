require "./spec_helper"

private def touch_backup(layout : Jawas::Layout, period : Jawas::Period, time : Time) : String
  path = layout.file_path("srv", period, "app", time, ".sql.gz")
  Dir.mkdir_p(File.dirname(path))
  File.write(path, "x")
  File.write("#{path}.sha256", "y")
  path
end

describe Jawas::Retention do
  now = Time.local(2026, 11, 16, 12, 0)

  it "supprime au-delà de la durée, en gardant keep_min" do
    SpecHelper.with_tmpdir do |dir|
      layout = Jawas::Layout.new(dir)
      paths = (0..9).map { |age| touch_backup(layout, Jawas::Period::Daily, now - age.days) }
      policy = Jawas::Config::Retention.new(daily: 3, weekly: 0, monthly: 0, keep_min: 2)
      retention = Jawas::Retention.new(layout, policy)

      planned = retention.prune(["srv"], now, apply: false)
      planned.map(&.path).sort!.should eq(paths[4..].sort)
      File.exists?(paths.last).should be_true

      retention.prune(["srv"], now, apply: true)
      paths[0..3].each { |path| File.exists?(path).should be_true }
      paths[4..].each do |path|
        File.exists?(path).should be_false
        File.exists?("#{path}.sha256").should be_false
      end
    end
  end

  it "garde keep_min sauvegardes même toutes périmées" do
    SpecHelper.with_tmpdir do |dir|
      layout = Jawas::Layout.new(dir)
      paths = (30..35).map { |age| touch_backup(layout, Jawas::Period::Daily, now - age.days) }
      policy = Jawas::Config::Retention.new(daily: 7, weekly: 0, monthly: 0, keep_min: 2)
      Jawas::Retention.new(layout, policy).prune(["srv"], now, apply: true)
      paths.select { |path| File.exists?(path) }.should eq(paths[0..1])
    end
  end

  it "ne purge pas une période dont la durée vaut 0" do
    SpecHelper.with_tmpdir do |dir|
      layout = Jawas::Layout.new(dir)
      path = touch_backup(layout, Jawas::Period::Monthly, now - 400.days)
      policy = Jawas::Config::Retention.new(daily: 7, weekly: 35, monthly: 0, keep_min: 0)
      Jawas::Retention.new(layout, policy).prune(["srv"], now, apply: true).should be_empty
      File.exists?(path).should be_true
    end
  end
end
