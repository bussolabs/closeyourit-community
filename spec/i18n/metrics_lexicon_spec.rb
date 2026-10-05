# frozen_string_literal: true

require "rails_helper"

# CYRA-343 — nell'elenco delle performance convivevano voci tradotte («Richiesta lenta») e
# identificatori grezzi presi dal codice («slow_query», «n_plus_one …»), e nel menu compariva
# «translation missing: it.member.nav.valhalla». Qui si blinda che categoria e tipo di problema
# abbiano SEMPRE una resa leggibile (it/en), che ogni voce dei filtri porti una spiegazione, e che
# la voce Valhalla del menu sia tradotta.
RSpec.describe "Lessico performance in italiano (CYRA-343)", type: :model do
  KIND_KEYS = %w[slow_query slow_method performance_issue].freeze
  SUBTYPE_KEYS = Metrics::Group::PERFORMANCE_SUBTYPES

  describe "categorie e tipi di problema hanno una resa leggibile (mai il valore grezzo)" do
    it "ogni categoria è tradotta in it e in en" do
      %w[it en].each do |locale|
        KIND_KEYS.each do |code|
          label = I18n.t("member.metrics.kind.#{code}", locale: locale, raise: true)
          expect(label).to be_present
          expect(label).not_to include("_") # nessun identificatore grezzo tipo "slow_query"
        end
      end
    end

    it "ogni tipo di problema è tradotto in it e in en" do
      %w[it en].each do |locale|
        SUBTYPE_KEYS.each do |code|
          label = I18n.t("member.metrics.subtype.#{code}", locale: locale, raise: true)
          expect(label).to be_present
          expect(label).not_to include("_")
        end
      end
    end

    it "usa davvero l'italiano nei casi citati dal ticket" do
      expect(I18n.t("member.metrics.kind.slow_query", locale: :it)).to eq("Query lenta")
      expect(I18n.t("member.metrics.kind.slow_method", locale: :it)).to eq("Metodo lento")
      expect(I18n.t("member.metrics.kind.performance_issue", locale: :it)).to eq("Problema di performance")
    end
  end

  describe "ogni voce dei filtri ha una riga che la spiega, in it e in en" do
    it "spiega ogni categoria" do
      %w[it en].each do |locale|
        KIND_KEYS.each do |code|
          expect(I18n.t("member.metrics.kind_hint.#{code}", locale: locale, raise: true)).to be_present
        end
      end
    end

    it "spiega ogni tipo di problema" do
      %w[it en].each do |locale|
        SUBTYPE_KEYS.each do |code|
          expect(I18n.t("member.metrics.subtype_hint.#{code}", locale: locale, raise: true)).to be_present
        end
      end
    end
  end

  # DoD: «L'avviso di traduzione mancante nel menu è sparito» — la voce Valhalla del menu è tradotta.
  describe "la voce Valhalla del menu è tradotta (niente translation missing)" do
    it "member.nav.valhalla è presente in it e in en" do
      %w[it en].each do |locale|
        expect(I18n.t("member.nav.valhalla", locale: locale, raise: true)).to be_present
      end
    end
  end
end
