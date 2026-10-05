# frozen_string_literal: true

require "rails_helper"

# CYRA-565 — in cima all'elenco delle vulnerabilità il chip «Totale» contava le sole aperte: con otto
# righe messe da parte in tabella la testata diceva «Totale: 0» e «Alte: 0» sopra sette righe «Alta».
# Qui si blinda la resa: i tre chip che contano solo le aperte lo dichiarano nel proprio nome, in
# italiano e in inglese, e la parola «totale» non torna su un numero che totale non è.
RSpec.describe "Nomi dei conteggi delle vulnerabilità (CYRA-565)", type: :model do
  OPEN_ONLY_STATS = %w[open critical high].freeze
  OPEN_WORD = { "it" => "apert", "en" => "open" }.freeze

  it "ogni chip che conta solo le aperte lo dice, in it e in en" do
    OPEN_WORD.each do |locale, word|
      OPEN_ONLY_STATS.each do |key|
        label = I18n.t("member.monitoring.vulnerabilities.stats.#{key}", locale: locale, raise: true)
        expect(label.downcase).to include(word),
                                  "«#{label}» (#{locale}/#{key}) non dice che conta le aperte"
      end
    end
  end

  it "non esiste più un chip che si chiama «totale»" do
    %w[it en].each do |locale|
      expect(I18n.exists?("member.monitoring.vulnerabilities.stats.total", locale)).to be(false)
    end
  end

  it "i chip che contano su tutti gli stati restano quelli di sempre" do
    expect(I18n.t("member.monitoring.vulnerabilities.stats.ignored", locale: :it)).to eq("Ignorate")
    expect(I18n.t("member.monitoring.vulnerabilities.stats.runtimes_eol", locale: :it))
      .to eq("Fuori supporto")
  end
end
