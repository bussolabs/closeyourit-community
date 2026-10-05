# frozen_string_literal: true

require "rails_helper"

# CYRA-439 — il contratto di leggibilità del catalogo: ogni chiave ha un nome umano e una riga che
# dice cosa comporta concederla, in entrambe le lingue. Una chiave nuova senza testi fa fallire qui,
# non in produzione davanti a chi deve decidere.
RSpec.describe Authorization::Catalog do
  %i[it en].each do |locale|
    it "ogni permesso ha un nome in #{locale}" do
      labels = I18n.t("authorization.permissions", locale:)
      missing = described_class.keys.reject { |key| labels[key.to_sym].present? }
      expect(missing).to be_empty
    end

    it "ogni permesso ha una riga che ne spiega l'effetto in #{locale}" do
      descriptions = I18n.t("authorization.permission_descriptions", locale:)
      missing = described_class.keys.reject { |key| descriptions[key.to_sym].present? }
      expect(missing).to be_empty
    end
  end

  # CYRA-574 — le aree sono i titoli dei gruppi nella pagina dei permessi. Ne mancavano due su
  # undici, e la pagina mostrava il segnaposto di i18n col messaggio d'errore nel tooltip, in mezzo
  # a nomi italiani. Un'area nuova senza nome fallisce qui, non davanti a chi assegna un ruolo.
  %i[it en].each do |locale|
    it "ogni area del catalogo ha un nome in #{locale}" do
      nomi = I18n.t("authorization.areas", locale:)
      missing = described_class.areas.reject { |area| nomi[area.to_sym].present? }
      expect(missing).to be_empty
    end
  end

  it "non ci sono nomi d'area orfani di aree che non esistono più" do
    nomi = I18n.t("authorization.areas", locale: :it).keys.map(&:to_s)
    expect(nomi - described_class.areas).to be_empty
  end

  it "non ci sono testi orfani di chiavi che non esistono più" do
    labels = I18n.t("authorization.permissions", locale: :it).keys.map(&:to_s)
    descriptions = I18n.t("authorization.permission_descriptions", locale: :it).keys.map(&:to_s)
    expect(labels - described_class.keys).to be_empty
    expect(descriptions - described_class.keys).to be_empty
  end

  describe ".dangerous?" do
    it "segnala i permessi che distruggono, aprono segreti, eseguono comandi o allargano privilegi" do
      expect(described_class.dangerous?("servers.execute")).to be(true)
      expect(described_class.dangerous?("secrets.read")).to be(true)
      expect(described_class.dangerous?("permissions.manage")).to be(true)
      expect(described_class.dangerous?("projects.delete")).to be(true)
    end

    it "non segnala le letture e le azioni reversibili" do
      expect(described_class.dangerous?("members.view")).to be(false)
      expect(described_class.dangerous?("errors.triage")).to be(false)
    end

    it "una chiave sconosciuta non è pericolosa (non esiste)" do
      expect(described_class.dangerous?("non.esiste")).to be(false)
    end
  end

  describe ".areas_for" do
    it "restituisce le aree nell'ordine del catalogo, senza ripetizioni" do
      areas = described_class.areas_for(%w[members.view tickets.edit tickets.delete])
      expect(areas).to eq(%w[tickets people])
    end

    it "ignora le chiavi che non esistono" do
      expect(described_class.areas_for(%w[non.esiste tickets.edit])).to eq(%w[tickets])
    end

    it "senza chiavi non ci sono aree" do
      expect(described_class.areas_for([])).to be_empty
    end
  end
end
