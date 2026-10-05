require "rails_helper"

RSpec.describe Projects::Token, type: :model do
  describe "factory" do
    it "produce un token valido" do
      expect(build(:project_token)).to be_valid
    end
  end

  describe "associazioni" do
    it "appartiene a un progetto" do
      expect(build(:project_token, project: nil)).not_to be_valid
    end

    it "created_by è opzionale" do
      expect(build(:project_token, created_by: nil)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede name" do
      expect(build(:project_token, name: nil)).not_to be_valid
    end

    it "richiede token_digest" do
      expect(build(:project_token, token_digest: nil)).not_to be_valid
    end

    it "richiede public_key" do
      expect(build(:project_token, public_key: nil)).not_to be_valid
    end

    it "token_digest è unico" do
      existing = create(:project_token)
      expect(build(:project_token, token_digest: existing.token_digest)).not_to be_valid
    end

    it "public_key è unica" do
      existing = create(:project_token)
      expect(build(:project_token, public_key: existing.public_key)).not_to be_valid
    end
  end

  describe "binding all'environment" do
    it "richiede un environment" do
      token = build(:project_token)
      token.environment = nil
      expect(token).not_to be_valid
    end

    it "è valido se l'environment è dichiarato dal progetto" do
      project = create(:project)
      env = create(:environment, organization: project.organization)
      project.environments << env
      expect(build(:project_token, project:, environment: env)).to be_valid
    end

    it "è invalido se l'environment NON è dichiarato dal progetto (subset constraint)" do
      project = create(:project)
      undeclared = create(:environment, organization: project.organization)
      expect(build(:project_token, project:, environment: undeclared)).not_to be_valid
    end

    it "è invalido se l'environment è di un'altra org" do
      project = create(:project)
      other_env = create(:environment, organization: create(:organization))
      expect(build(:project_token, project:, environment: other_env)).not_to be_valid
    end
  end

  describe ".active" do
    it "include i token non revocati ed esclude i revocati" do
      active = create(:project_token)
      revoked = create(:project_token, :revoked)

      expect(described_class.active).to include(active)
      expect(described_class.active).not_to include(revoked)
    end

    it "esclude i token scaduti e include quelli senza scadenza o con scadenza futura (CYRA-716)" do
      senza_scadenza = create(:project_token)
      futuro = create(:project_token, expires_at: 1.day.from_now)
      scaduto = create(:project_token, :expired)

      expect(described_class.active).to include(senza_scadenza, futuro)
      expect(described_class.active).not_to include(scaduto)
    end
  end

  describe "scadenza (CYRA-716)" do
    describe "validazione" do
      it "rifiuta una scadenza già passata alla creazione" do
        token = build(:project_token, expires_at: 1.minute.ago)
        expect(token).not_to be_valid
        expect(token.errors[:expires_at]).to be_present
      end

      it "accetta una scadenza futura e l'assenza di scadenza" do
        expect(build(:project_token, expires_at: 30.days.from_now)).to be_valid
        expect(build(:project_token, expires_at: nil)).to be_valid
      end

      it "non blocca l'aggiornamento di un token già scaduto (la validazione è solo alla creazione)" do
        token = create(:project_token, :expired)
        expect(token.update(last_used_at: Time.current)).to be(true)
      end
    end

    describe "#expired?" do
      it "false senza scadenza, false con scadenza futura, true con scadenza passata" do
        expect(build(:project_token, expires_at: nil).expired?).to be(false)
        expect(build(:project_token, expires_at: 1.hour.from_now).expired?).to be(false)
        expect(build(:project_token, expires_at: 1.hour.ago).expired?).to be(true)
      end

      it "l'istante esatto della scadenza è già scaduto (nessuna finestra di tolleranza)" do
        travel_to(Time.current) do
          expect(build(:project_token, expires_at: Time.current).expired?).to be(true)
        end
      end
    end

    describe "#expiry_status" do
      it ":none senza scadenza" do
        expect(build(:project_token, expires_at: nil).expiry_status).to eq(:none)
      end

      it ":expired quando la data è passata" do
        expect(build(:project_token, expires_at: 1.day.ago).expiry_status).to eq(:expired)
      end

      it ":due_soon dentro la finestra di preavviso" do
        expect(build(:project_token, :expiring_soon).expiry_status).to eq(:due_soon)
      end

      it ":ok oltre la finestra di preavviso" do
        oltre = described_class::EXPIRY_DUE_SOON_THRESHOLD + 1.day
        expect(build(:project_token, expires_at: oltre.from_now).expiry_status).to eq(:ok)
      end
    end

    describe "#days_until_expiry" do
      it "nil senza scadenza, positivo se manca, negativo se superata" do
        expect(build(:project_token, expires_at: nil).days_until_expiry).to be_nil
        expect(build(:project_token, expires_at: 3.days.from_now).days_until_expiry).to eq(3)
        expect(build(:project_token, expires_at: 2.days.ago).days_until_expiry).to eq(-2)
      end
    end

    describe ".due_for_expiry" do
      it "include i token in preavviso e quelli già scaduti" do
        in_preavviso = create(:project_token, :expiring_soon)
        scaduto = create(:project_token, :expired)

        expect(described_class.due_for_expiry).to include(in_preavviso, scaduto)
      end

      it "esclude i token senza scadenza, quelli lontani e quelli revocati" do
        senza = create(:project_token)
        lontano = create(:project_token, expires_at: (described_class::EXPIRY_DUE_SOON_THRESHOLD + 1.day).from_now)
        revocato = create(:project_token, :expiring_soon, revoked_at: Time.current)

        expect(described_class.due_for_expiry).not_to include(senza, lontano, revocato)
      end
    end
  end

  describe "#revoked?" do
    it "true se revoked_at presente, false altrimenti" do
      expect(build(:project_token, :revoked).revoked?).to be(true)
      expect(build(:project_token).revoked?).to be(false)
    end
  end

  describe "#scope?" do
    it "true se lo scope è presente (accetta symbol o string)" do
      token = build(:project_token, scopes: [ "ingest", "read" ])
      expect(token.scope?(:ingest)).to be(true)
      expect(token.scope?("read")).to be(true)
    end

    it "false se lo scope è assente" do
      expect(build(:project_token, :ingest_only).scope?(:read)).to be(false)
      expect(build(:project_token, :read_only).scope?(:ingest)).to be(false)
    end
  end

  describe "#to_dsn" do
    it "compone il DSN Sentry-style con public_key, host e project_id" do
      token = build(:project_token, public_key: "abc123")
      allow(token).to receive(:project_id).and_return("proj-uuid")

      expect(token.to_dsn(host: "bugs.example.com"))
        .to eq("https://abc123@bugs.example.com/proj-uuid")
    end
  end

  describe "#stale_usage?" do
    it "true se last_used_at è nil" do
      expect(build(:project_token, last_used_at: nil).stale_usage?).to be(true)
    end

    it "true se last_used_at è oltre la soglia (1s prima)" do
      travel_to(Time.current) do
        token = build(:project_token, last_used_at: 1.minute.ago - 1.second)
        expect(token.stale_usage?).to be(true)
      end
    end

    it "false se last_used_at è entro la soglia (1s dopo)" do
      travel_to(Time.current) do
        token = build(:project_token, last_used_at: 1.minute.ago + 1.second)
        expect(token.stale_usage?).to be(false)
      end
    end
  end
end
