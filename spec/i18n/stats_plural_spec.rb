# frozen_string_literal: true

require "rails_helper"

# M5 — a count line reads "1 team", never "1 teams": every counted noun under `stats.` has a
# singular and a plural, and every page passes the number it shows.
RSpec.describe "Shared count words (stats.*)" do
  counted = %w[projects groups tickets roles workload_actions teams open_questions members warnings
               versions variables service_accounts platforms organizations logs lists files exceptions
               errors environments conversations accounts]

  %i[en it].each do |locale|
    counted.each do |key|
      it "#{locale}: stats.#{key} has a singular and a plural" do
        forms = I18n.t("stats.#{key}", locale: locale, raise: true)
        expect(forms).to be_a(Hash)
        expect(forms.keys).to contain_exactly(:one, :other)
      end
    end
  end

  it "says the singular for one and the plural otherwise" do
    expect(I18n.t("stats.teams", count: 1, locale: :en)).to eq("Team")
    expect(I18n.t("stats.teams", count: 2, locale: :en)).to eq("Teams")
    expect(I18n.t("stats.groups", count: 1, locale: :it)).to eq("Gruppo")
    expect(I18n.t("stats.groups", count: 0, locale: :it)).to eq("Gruppi")
  end

  it "is never called without its count" do
    pattern = /t\("stats\.(#{counted.join('|')})"\)/
    offenders = Dir[Rails.root.join("app/**/*.{erb,rb}")].select { |file| File.read(file).match?(pattern) }
    expect(offenders.map { |file| Pathname(file).relative_path_from(Rails.root).to_s }).to eq([])
  end
end
