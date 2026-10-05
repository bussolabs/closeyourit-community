# frozen_string_literal: true

require "rails_helper"

# CYRA-438 — la voce che porta alle guide si leggeva «translation missing: it.member.nav.guides»
# dentro un menu per il resto italiano: dieci etichette di navigazione erano finite annidate sotto
# `member.shared_secrets`, quindi non esistevano dove il layout le cercava. Il guard di CYRA-343
# blindava la sola voce Valhalla, una chiave alla volta, e non poteva accorgersene.
#
# Qui il controllo segue il CODICE: raccoglie ogni `member.nav.*` usata nelle viste e nei componenti
# e pretende che esista in italiano e in inglese. Una voce nuova senza testo fa fallire la suite,
# quindi la CI, quindi il rilascio: il segnaposto non arriva a chi usa il prodotto.
#
# Limitato di proposito alle chiavi di navigazione (`member.nav.*`): allargarlo a tutto il prodotto
# lo farebbe fallire sui testi ancora fuori da i18n, e un guard che fallisce sempre non lo guarda più
# nessuno.
used_nav_keys = Dir.glob(Rails.root.join("app/**/*.{erb,rb}")).flat_map { |file|
  File.read(file).scan(/["']member\.nav\.([a-z_]+)["']/).flatten
}.uniq.sort

RSpec.describe "Voci di navigazione tradotte (CYRA-438)", type: :model do
  it "il menu usa almeno una voce (il guard non gira a vuoto)" do
    expect(used_nav_keys.size).to be > 20
  end

  %w[it en].each do |locale|
    it "ogni voce del menu ha il suo testo in #{locale}" do
      missing = used_nav_keys.reject do |key|
        I18n.t("member.nav.#{key}", locale: locale, default: nil).present?
      end

      expect(missing).to be_empty,
                         "voci di menu senza testo in #{locale}: #{missing.join(', ')}. " \
                         "Aggiungile sotto member.nav in config/locales/member/#{locale}.yml."
    end
  end

  it "la voce delle guide si legge «Guide» in italiano" do
    expect(I18n.t("member.nav.guides", locale: :it, raise: true)).to eq("Guide")
  end
end
