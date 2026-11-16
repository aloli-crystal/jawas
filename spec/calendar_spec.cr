require "./spec_helper"

describe Jawas::Calendar do
  it "produit toujours daily" do
    Jawas::Calendar.periods_for(Time.local(2026, 11, 17), 6, 1).should eq([Jawas::Period::Daily])
  end

  it "ajoute weekly le jour ISO configuré (6 = samedi)" do
    Jawas::Calendar.periods_for(Time.local(2026, 11, 21), 6, 1).should eq([Jawas::Period::Daily, Jawas::Period::Weekly])
  end

  it "ajoute monthly le jour du mois configuré" do
    Jawas::Calendar.periods_for(Time.local(2026, 12, 1), 6, 1).should eq([Jawas::Period::Daily, Jawas::Period::Monthly])
  end

  it "ramène un jour 31 au dernier jour des mois courts" do
    Jawas::Calendar.periods_for(Time.local(2026, 2, 28), 0, 31).should contain(Jawas::Period::Monthly)
    Jawas::Calendar.periods_for(Time.local(2028, 2, 28), 0, 31).should_not contain(Jawas::Period::Monthly)
    Jawas::Calendar.periods_for(Time.local(2028, 2, 29), 0, 31).should contain(Jawas::Period::Monthly)
  end

  it "désactive weekly et monthly avec 0" do
    Jawas::Calendar.periods_for(Time.local(2026, 11, 1), 0, 0).should eq([Jawas::Period::Daily])
  end
end
