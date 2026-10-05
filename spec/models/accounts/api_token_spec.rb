require "rails_helper"

RSpec.describe Accounts::ApiToken, type: :model do
  describe "factory" do
    it "produce un token valido" do
      expect(build(:api_token)).to be_valid
    end
  end

  describe "associazioni" do
    it "richiede un account" do
      expect(build(:api_token, account: nil)).not_to be_valid
    end

    it "richiede un'organizzazione" do
      expect(build(:api_token, organization: nil)).not_to be_valid
    end
  end

  describe "validazioni" do
    it "richiede name" do
      expect(build(:api_token, name: nil)).not_to be_valid
    end

    it "richiede token_digest" do
      expect(build(:api_token, token_digest: nil)).not_to be_valid
    end

    it "richiede token_prefix" do
      expect(build(:api_token, token_prefix: nil)).not_to be_valid
    end

    it "token_digest è unico" do
      existing = create(:api_token)
      expect(build(:api_token, token_digest: existing.token_digest)).not_to be_valid
    end

    # CYRA-717 — un token che NASCE già scaduto è sempre un errore di digitazione, mai un'intenzione.
    it "rifiuta una scadenza nel passato alla creazione" do
      token = build(:api_token, expires_at: 1.hour.ago)
      expect(token).not_to be_valid
      expect(token.errors[:expires_at]).to be_present
    end

    it "un token già scaduto resta aggiornabile (la validazione è solo on: :create)" do
      token = create(:api_token, :expired)
      token.last_used_at = Time.current
      expect(token.save).to be(true)
    end
  end

  describe "integrità tenant" do
    it "è invalido se l'account NON è membro dell'organizzazione" do
      account = create(:account)
      organization = create(:organization)
      token = build(:api_token, account:, organization:)
      # Rimuove l'eventuale membership creata dalla factory per testare il guard.
      Connections::Membership.where(account:, organization:).delete_all
      expect(token).not_to be_valid
      expect(token.errors[:account]).to be_present
    end

    it "è valido se l'account è membro dell'organizzazione" do
      account = create(:account)
      organization = create(:organization)
      create(:membership, account:, organization:)
      expect(build(:api_token, account:, organization:)).to be_valid
    end
  end

  describe ".active" do
    it "include i token non revocati e non scaduti" do
      token = create(:api_token)
      expect(described_class.active).to include(token)
    end

    it "esclude i token revocati" do
      token = create(:api_token, :revoked)
      expect(described_class.active).not_to include(token)
    end

    it "esclude i token scaduti" do
      token = create(:api_token, :expired)
      expect(described_class.active).not_to include(token)
    end

    it "include i token senza scadenza (expires_at nil)" do
      token = create(:api_token, expires_at: nil)
      expect(described_class.active).to include(token)
    end

    it "al confine della scadenza: attivo 1s prima, escluso 1s dopo" do
      freeze_time do
        token = create(:api_token, expires_at: 1.second.from_now)
        expect(described_class.active).to include(token)

        travel 2.seconds
        expect(described_class.active).not_to include(token)
      end
    end
  end

  describe "#revoked?" do
    it "true se revocato" do
      expect(build(:api_token, :revoked).revoked?).to be(true)
    end

    it "false se non revocato" do
      expect(build(:api_token).revoked?).to be(false)
    end
  end

  describe "#expired?" do
    it "true se scaduto" do
      expect(build(:api_token, :expired).expired?).to be(true)
    end

    it "false se senza scadenza" do
      expect(build(:api_token, expires_at: nil).expired?).to be(false)
    end
  end

  # CYRA-717 — lo stato che leggono la pagina token e la riga di comando.
  describe "#expiry_status" do
    it ":none senza scadenza" do
      expect(build(:api_token, expires_at: nil).expiry_status).to eq(:none)
    end

    it ":ok se la scadenza è oltre la finestra di preavviso" do
      expect(build(:api_token, expires_at: 30.days.from_now).expiry_status).to eq(:ok)
    end

    it ":due_soon se la scadenza è dentro la finestra di preavviso" do
      expect(build(:api_token, expires_at: 3.days.from_now).expiry_status).to eq(:due_soon)
    end

    it ":expired se la scadenza è passata" do
      expect(build(:api_token, :expired).expiry_status).to eq(:expired)
    end

    it "al confine: :due_soon un'ora prima della soglia, :ok un'ora dopo" do
      soglia = described_class::EXPIRY_DUE_SOON_THRESHOLD
      expect(build(:api_token, expires_at: soglia.from_now - 1.hour).expiry_status).to eq(:due_soon)
      expect(build(:api_token, expires_at: soglia.from_now + 1.hour).expiry_status).to eq(:ok)
    end
  end

  describe "#days_until_expiry" do
    it "nil senza scadenza" do
      expect(build(:api_token, expires_at: nil).days_until_expiry).to be_nil
    end

    it "positivo se la scadenza deve ancora arrivare" do
      expect(build(:api_token, expires_at: 5.days.from_now).days_until_expiry).to eq(5)
    end

    it "negativo se la scadenza è passata" do
      expect(build(:api_token, expires_at: 2.days.ago).days_until_expiry).to eq(-2)
    end
  end

  describe "#stale_usage?" do
    it "true se mai usato" do
      expect(build(:api_token, last_used_at: nil).stale_usage?).to be(true)
    end

    it "false se usato di recente" do
      expect(build(:api_token, last_used_at: Time.current).stale_usage?).to be(false)
    end
  end
end
