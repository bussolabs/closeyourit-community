# frozen_string_literal: true

require "rails_helper"

# CYRA-544 — il registro dei servizi collegabili. È dev-defined come `Ai::Feature`: ogni voce ha un
# punto d'innesto scritto nel codice, quindi aggiungerne una è lavoro di sviluppo e questo guard
# tiene insieme le tre cose che devono cambiare insieme — registro, testi, verifica.
RSpec.describe Integrations::Providers do
  # Dal CYRA-765 ne resta uno solo: l'assistenza AI non è più una chiave da collegare, la mette il
  # sistema. Il conto è scritto qui apposta — se qualcuno rimette un fornitore nel registro senza
  # testi né sonda, questa riga lo dice prima della pagina.
  it "elenca il solo servizio collegabile rimasto" do
    expect(described_class.keys).to eq(%w[pagespeed])
  end

  it "un servizio che non c'è non è conosciuto, e cercarlo dà nil invece di sollevare" do
    expect(described_class).not_to be_known("inventato")
    expect(described_class.find("inventato")).to be_nil
  end

  # Un servizio senza testi comparirebbe in pagina come «translation missing», che è peggio del non
  # averlo aggiunto.
  %i[it en].each do |lingua|
    it "in #{lingua} ogni servizio ha nome, spiegazione e dove si prende la chiave" do
      described_class.all.each do |servizio|
        %w[label summary where].each do |campo|
          testo = I18n.t("integrations.providers.#{servizio.key}.#{campo}", locale: lingua, default: "")
          expect(testo).to be_present, "manca integrations.providers.#{servizio.key}.#{campo} in #{lingua}"
        end
      end
    end

    it "in #{lingua} ogni funzione che un servizio accende ha un nome" do
      described_class.all.flat_map(&:features).uniq.each do |funzione|
        testo = I18n.t("integrations.features.#{funzione}", locale: lingua, default: "")
        expect(testo).to be_present, "manca integrations.features.#{funzione} in #{lingua}"
      end
    end

    # Si itera sugli esiti DICHIARATI, non su un elenco copiato: un esito nuovo senza il suo testo
    # comparirebbe a schermo come «translation missing», e un elenco a mano non se ne accorgerebbe.
    it "in #{lingua} ogni esito della verifica ha una spiegazione che dice cosa fare" do
      Integrations::Verify::OUTCOMES.each_key do |codice|
        testo = I18n.t("integrations.errors.#{codice}", locale: lingua, default: "")
        expect(testo).to be_present, "manca integrations.errors.#{codice} in #{lingua}"
      end
    end
  end

  # Chi collega una chiave deve sapere dove andarla a prendere: è l'unica cosa che non può indovinare.
  it "ogni servizio dice dove si crea la chiave" do
    described_class.all.each do |servizio|
      expect(servizio.console_url).to start_with("https://")
      expect(servizio.features).not_to be_empty
    end
  end

  # Il registro deve restare allineato a chi lo sa verificare: un servizio che si può collegare ma
  # non si può provare tornerebbe al mistero silenzioso da cui questa lavorazione vuole uscire.
  #
  # Si confrontano le CHIAVI delle due mappe. La versione precedente chiamava `Verify` con una chiave
  # vuota e si aspettava «chiave non valida»: quel controllo esce PRIMA di scegliere il fornitore,
  # quindi passava identico anche per un servizio che nessuno sapeva verificare. Non provava niente.
  it "registro e verifica hanno esattamente gli stessi servizi" do
    expect(Integrations::Verify::PROBES.keys).to match_array(described_class.keys)
  end
end
