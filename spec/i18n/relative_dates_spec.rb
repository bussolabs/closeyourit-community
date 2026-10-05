# frozen_string_literal: true

require "rails_helper"

# CYRA-324 — «4 days fa», «about 1 hour fa»: né italiano né inglese, ed era il difetto più ripetuto
# della Home. Le chiavi ci sono (CYRA-392); questa spec impedisce che tornino a mancare, e verifica
# ogni intervallo che `distance_of_time_in_words` può produrre — dai secondi agli anni.
RSpec.describe "Date relative in italiano", type: :helper do
  include ActionView::Helpers::DateHelper

  # Una durata per ogni ramo di ActionView::Helpers::DateHelper#distance_of_time_in_words.
  DURATIONS = {
    "meno di un minuto" => 10.seconds,
    "minuti" => 90.seconds,
    "un'ora" => 62.minutes,
    "ore" => 3.hours,
    "un giorno" => 26.hours,
    "giorni" => 4.days,
    "un mese" => 40.days,
    "mesi" => 70.days,
    "un anno" => 400.days,
    "anni" => 3.years
  }.freeze

  DURATIONS.each do |label, duration|
    it "«#{label}» non contiene parole inglesi" do
      text = I18n.with_locale(:it) { time_ago_in_words(Time.current - duration) }

      expect(text).not_to match(/\b(about|less than|almost|over|day|days|hour|hours|minute|minutes|second|seconds|month|months|year|years)\b/)
      expect(text).not_to include("translation missing")
    end
  end

  it "copre tutte le chiavi che Rails può emettere" do
    keys = I18n.t("datetime.distance_in_words", locale: :it).keys.map(&:to_s)

    expect(keys).to include("half_a_minute", "less_than_x_seconds", "x_seconds", "less_than_x_minutes",
                            "x_minutes", "about_x_hours", "x_days", "about_x_months", "x_months",
                            "about_x_years", "over_x_years", "almost_x_years")
  end

  it "i nomi di giorni e mesi italiani sono quelli italiani" do
    expect(I18n.t("date.abbr_day_names", locale: :it)).to include("lun", "gio")
    expect(I18n.t("date.abbr_month_names", locale: :it)).to include("ago", "dic")
  end

  # CYRA-497 — una data scritta a mano con strftime non guarda la lingua: usciva «Aggiornato il
  # 09 Aug 15:14» in mezzo a una pagina italiana. I nomi di giorni e mesi si prendono dai formati,
  # che leggono le liste qui sopra.
  it "nessuna vista scrive i nomi di giorni e mesi con strftime" do
    a_mano = Dir.glob(Rails.root.join("app/**/*.{erb,rb}")).filter_map do |file|
      righe = File.readlines(file).each_with_index.select do |riga, _|
        riga.include?("strftime") && riga.match?(/%[-_]?[bBaA]/)
      end
      righe.map { |riga, i| "#{Pathname(file).relative_path_from(Rails.root)}:#{i + 1}" } if righe.any?
    end.flatten

    expect(a_mano).to be_empty
  end

  # CYRA-453 — stesso difetto per un'altra strada: `to_fs(:short)` stampa il formato di default di
  # Rails («09 Aug 15:14»), che non guarda la lingua scelta. Le date in pagina passano da `l`.
  it "nessuna vista scrive una data col formato di default di Rails" do
    a_mano = Dir.glob(Rails.root.join("app/{views,components,helpers,presenters}/**/*.{erb,rb}")).filter_map do |file|
      righe = File.readlines(file).each_with_index.select do |riga, _|
        riga.match?(/to_fs\(:(short|long|default)\)/)
      end
      righe.map { |riga, i| "#{Pathname(file).relative_path_from(Rails.root)}:#{i + 1}" } if righe.any?
    end.flatten

    expect(a_mano).to be_empty
  end

  it "i formati con il mese scrivono il mese in italiano" do
    data = Date.new(2026, 8, 9)

    expect(I18n.l(data, format: :day_month, locale: :it)).to eq("9 ago")
    expect(I18n.l(data, format: :day_month_year, locale: :it)).to eq("9 ago 2026")
  end
end
