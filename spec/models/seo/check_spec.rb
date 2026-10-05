# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::Check do
  it "ogni controllo dichiara area, gravità e ambito validi" do
    described_class.all.each do |check|
      expect(described_class::AREAS).to include(check.area), "area ignota su #{check.key}"
      expect(described_class::SEVERITIES).to include(check.severity), "gravità ignota su #{check.key}"
      expect(%i[page site]).to include(check.scope), "ambito ignoto su #{check.key}"
    end
  end

  it "riconosce solo le chiavi del registro" do
    expect(described_class).to be_known("missing_h1")
    expect(described_class).not_to be_known("controllo_inventato")
    expect(described_class.find("controllo_inventato")).to be_nil
  end

  it "separa i controlli di pagina da quelli d'insieme" do
    expect(described_class.page_scoped.map(&:key)).to include("missing_h1")
    # I duplicati non esistono su una pagina sola: si vedono solo confrontandole fra loro.
    expect(described_class.site_scoped.map(&:key)).to include("duplicate_title")
    expect(described_class.page_scoped & described_class.site_scoped).to be_empty
  end

  it "raggruppa per area di lettura" do
    expect(described_class.for_area("indexability").map(&:key)).to include("noindex")
    expect(described_class.for_area("i18n").map(&:key)).to include("hreflang_not_reciprocal")
  end

  it "resta leggibile anche senza traduzione: l'etichetta ripiega sulla chiave" do
    check = described_class.new("chiave_senza_traduzione")
    expect(check.label).to eq("chiave_senza_traduzione")
    expect(check.explanation).to eq("")
  end

  it "espone le soglie in un posto solo" do
    expect(described_class.threshold(:title_max_length)).to be_a(Integer)
    expect(described_class.threshold(:thin_content_words)).to be_positive
  end

  it "due istanze della stessa chiave sono la stessa cosa" do
    expect(described_class.new("noindex")).to eq(described_class.new("noindex"))
    expect(described_class.new("noindex")).not_to eq(described_class.new("missing_h1"))
  end

  # CYRA-808 — ogni controllo dice DA COSA si capisce che è stato eseguito. Senza, un giro che non
  # ha letto la pagina somiglia a un giro che l'ha letta e non ha trovato niente.
  it "ogni controllo dichiara cosa serve per potersi dire eseguito" do
    described_class.all.each do |check|
      expect(described_class::OBSERVATIONS).to include(check.needs), "requisito ignoto su #{check.key}"
    end
  end

  it "un controllo si dice eseguito solo da quel livello di osservazione in su" do
    titolo = described_class.new("missing_title")
    expect(titolo.needs).to eq(:analyzed)
    expect(titolo).to be_verifiable_with(:analyzed)
    expect(titolo).not_to be_verifiable_with(:responded)
    expect(titolo).not_to be_verifiable_with(:attempted)

    rotto = described_class.new("broken_link")
    expect(rotto).to be_verifiable_with(:analyzed)
    expect(rotto).to be_verifiable_with(:responded)
    expect(rotto).not_to be_verifiable_with(:attempted)

    vietata = described_class.new("blocked_by_robots")
    expect(vietata).to be_verifiable_with(:attempted)
  end

  # Un controllo fuori registro non deve poter essere chiuso da un giro cieco: chi non si conosce
  # pretende la prova più forte.
  it "un controllo sconosciuto pretende la pagina letta" do
    check = described_class.new("chiave_senza_registro")
    expect(check.needs).to eq(:analyzed)
    expect(check).not_to be_verifiable_with(:responded)
  end
end
