# frozen_string_literal: true

require "rails_helper"

# CYRA-775 — il registro dei rifiuti: l'unico canale che porta al giudizio sulla salute delle
# macchine l'informazione che il silenzio è NOSTRO (abbiamo risposto 429 a un agent), non della
# macchina. In test la cache è :null_store → ogni esempio ne monta una vera, o il registro
# scriverebbe nel vuoto e ricorderebbe sempre "nessun rifiuto".
RSpec.describe Servers::IngestRejections, type: :model do
  let(:window) { Servers::Constants::INGEST_REJECTION_WINDOW_SECONDS }

  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  # La chiave con cui il freno conta: il prefisso del digest del segreto presentato.
  def key_for(secret) = Digest::SHA256.hexdigest(secret)[0, 32]

  describe "memoria delle credenziali rifiutate" do
    it "senza rifiuti non c'è niente da sospendere" do
      expect(described_class.recent_keys).to be_empty
      expect(described_class.organization_ids).to be_empty
    end

    it "ricorda la credenziale rifiutata, mai il segreto" do
      described_class.record!(key_for("cyi_s_segreto"))

      expect(described_class.recent_keys).to contain_exactly(key_for("cyi_s_segreto"))
      expect(Rails.cache.read(described_class::CACHE_KEY).to_s).not_to include("cyi_s_segreto")
    end

    it "senza credenziale non registra niente: non c'è nessuno a cui attribuire il rifiuto" do
      expect(described_class.record!(nil)).to be_nil
      expect(described_class.record!("")).to be_nil
      expect(described_class.recent_keys).to be_empty
    end

    it "passata la finestra il rifiuto non copre più: il silenzio torna a valere come guasto" do
      described_class.record!(key_for("cyi_s_segreto"))

      travel((window + 1).seconds) { expect(described_class.recent_keys).to be_empty }
    end

    it "un rifiuto nuovo sposta in avanti la finestra: un episodio lungo resta coperto per intero" do
      described_class.record!(key_for("cyi_s_segreto"))

      travel((window - 1).seconds) { described_class.record!(key_for("cyi_s_segreto")) }
      travel((window + 1).seconds) { expect(described_class.recent_keys).to be_present }
    end

    it "tiene le credenziali più recenti e non cresce oltre il tetto" do
      (described_class::MAX_TRACKED_KEYS + 5).times { |n| described_class.record!(key_for("token-#{n}")) }

      keys = described_class.recent_keys
      expect(keys.size).to eq(described_class::MAX_TRACKED_KEYS)
      expect(keys).to include(key_for("token-#{described_class::MAX_TRACKED_KEYS + 4}"))
    end

    # La cache non è un archivio: senza scadenza una riga scritta una volta resterebbe a raccontare
    # per sempre un rifiuto di mesi prima.
    it "la riga scade da sé" do
      described_class.record!(key_for("cyi_s_segreto"))

      travel((window + 60).seconds) { expect(Rails.cache.read(described_class::CACHE_KEY)).to be_nil }
    end
  end

  # Il punto del ticket dopo la revisione: il freno scatta anche su un Bearer inventato, quindi
  # ricordare «è successo qualcosa» sarebbe stato un interruttore armabile da chiunque per spegnere
  # la rilevazione dei guasti di tutte le organizzazioni. Si sospende solo chi ha una credenziale
  # vera, e solo la sua organizzazione.
  describe "risoluzione delle organizzazioni" do
    it "la credenziale di una macchina sospende la SUA organizzazione" do
      host = create(:server_host)
      issued = Servers::HostTokens::Issue.call(host: host)

      described_class.record!(key_for(issued.value[:secret]))

      expect(described_class.organization_ids).to contain_exactly(host.organization_id)
    end

    it "il codice della flotta sospende l'organizzazione a cui appartiene" do
      organization = create(:organization)
      issued = Servers::EnrollmentTokens::Issue.call(organization: organization, name: "flotta")

      described_class.record!(key_for(issued.value[:secret]))

      expect(described_class.organization_ids).to contain_exactly(organization.id)
    end

    it "una credenziale inventata non sospende nessuno" do
      create(:server_host)

      described_class.record!(key_for("cyi_s_maiemesso"))

      expect(described_class.organization_ids).to be_empty
    end

    it "una credenziale revocata non sospende più nessuno" do
      host = create(:server_host)
      issued = Servers::HostTokens::Issue.call(host: host)
      host.host_tokens.update_all(revoked_at: Time.current)

      described_class.record!(key_for(issued.value[:secret]))

      expect(described_class.organization_ids).to be_empty
    end

    it "non sospende le organizzazioni che non abbiamo rifiutato" do
      rifiutata = create(:server_host)
      create(:server_host)
      issued = Servers::HostTokens::Issue.call(host: rifiutata)

      described_class.record!(key_for(issued.value[:secret]))

      expect(described_class.organization_ids).to contain_exactly(rifiutata.organization_id)
    end
  end
end
