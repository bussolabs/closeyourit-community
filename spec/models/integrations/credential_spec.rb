# frozen_string_literal: true

require "rails_helper"

RSpec.describe Integrations::Credential do
  let(:organization) { create(:organization) }

  describe "cosa si può salvare" do
    it "un servizio per organizzazione: si sostituisce, non si accumula" do
      create(:integration_credential, organization:, provider: "pagespeed")
      doppione = build(:integration_credential, organization:, provider: "pagespeed")

      expect(doppione).not_to be_valid
    end

    it "due organizzazioni possono collegare lo stesso servizio" do
      create(:integration_credential, organization:, provider: "pagespeed")

      expect(build(:integration_credential, organization: create(:organization), provider: "pagespeed")).to be_valid
    end

    it "un servizio che non è nel registro non entra" do
      expect(build(:integration_credential, organization:, provider: "inventato")).not_to be_valid
    end

    it "una chiave vuota non entra" do
      expect(build(:integration_credential, organization:, api_key: "   ")).not_to be_valid
    end

    it "gli spazi intorno alla chiave si tolgono: incollare da una pagina web ne porta sempre" do
      credenziale = create(:integration_credential, organization:, api_key: "  AIza-con-spazi\n")

      expect(credenziale.reload.api_key).to eq("AIza-con-spazi")
    end
  end

  # Il punto delicato: una credenziale è una credenziale. Non deve comparire dove finisce per caso
  # un oggetto — un log, un backtrace, una console.
  describe "la chiave non si fa vedere" do
    subject(:credenziale) { create(:integration_credential, organization:, api_key: "AIza-segretissima") }

    it "non compare in inspect" do
      expect(credenziale.inspect).not_to include("AIza-segretissima")
      expect(credenziale.inspect).to include(credenziale.provider)
    end

    it "sul disco è cifrata: chi legge la colonna non legge la chiave" do
      grezzo = described_class.connection.select_value(
        described_class.sanitize_sql_array([ "SELECT api_key FROM integrations_credentials WHERE id = ?", credenziale.id ])
      )

      expect(grezzo).not_to include("AIza-segretissima")
    end

    # Serve alla pagina: dire «collegata» senza decifrare niente.
    it "si può sapere che c'è senza leggerla" do
      expect(credenziale.api_key?).to be(true)
    end
  end

  # Il punto in cui la pagina potrebbe mentire: l'esito salvato parla della chiave con cui è stato
  # ottenuto. Se resta attaccato a una chiave nuova, la pagina dice «verificata» di una credenziale
  # che nessuno ha mai provato.
  describe "sostituire la chiave dimentica la verifica precedente" do
    subject(:credenziale) { create(:integration_credential, :verified, organization:) }

    it "una chiave nuova non eredita il «verificata» della vecchia" do
      credenziale.update!(api_key: "AIza-nuova-mai-provata")

      expect(credenziale.reload.verified_at).to be_nil
      expect(credenziale).not_to be_verified
    end

    it "nemmeno l'errore della vecchia resta appiccicato" do
      rotta = create(:integration_credential, :broken, organization: create(:organization))

      rotta.update!(api_key: "AIza-nuova")

      expect(rotta.reload.verification_error).to be_nil
      expect(rotta).not_to be_broken
    end

    # Chi salva chiave ed esito insieme sta scrivendo la prova della chiave NUOVA: buttarla via
    # costringerebbe a due giri per ogni collegamento.
    it "ma un esito scritto nello stesso salvataggio resta: è la prova della chiave nuova" do
      credenziale.update!(api_key: "AIza-nuova", verified_at: Time.current, verification_error: nil)

      expect(credenziale.reload).to be_verified
    end

    it "e salvare altro non tocca la verifica" do
      atteso = credenziale.verified_at

      credenziale.update!(connected_by: create(:account))

      expect(credenziale.reload.verified_at).to be_within(1.second).of(atteso)
    end
  end

  describe "lo stato dell'ultima prova" do
    it "distingue verificata, mai provata e rotta" do
      verificata = create(:integration_credential, :verified, organization:)
      rotta = create(:integration_credential, :broken, organization: create(:organization))
      mai = create(:integration_credential, organization: create(:organization))

      expect(verificata).to be_verified
      expect(verificata).not_to be_broken

      expect(rotta).to be_broken
      expect(rotta).not_to be_verified

      # Mai provata NON è rotta: una chiave appena incollata non è una chiave che non funziona.
      expect(mai).not_to be_broken
      expect(mai).not_to be_verified
    end
  end

  # Una credenziale non cambia padrone né servizio: si crea e si sostituisce. Spostarla su un'altra
  # organizzazione sarebbe il modo più diretto di consegnare una chiave a chi non deve averla.
  describe "cosa non si cambia più dopo il salvataggio" do
    subject(:credenziale) { create(:integration_credential, organization:, provider: "pagespeed") }

    it "non si sposta su un'altra organizzazione" do
      expect { credenziale.update!(organization: create(:organization)) }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "non si cambia servizio" do
      expect { credenziale.update!(provider: "pagespeed") }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "la chiave invece si sostituisce: è l'unica cosa che si aggiorna" do
      credenziale.update!(api_key: "AIza-nuova")

      expect(credenziale.reload.api_key).to eq("AIza-nuova")
    end
  end

  it "conosce il servizio del registro, e non esplode se quel servizio non c'è più" do
    credenziale = create(:integration_credential, organization:, provider: "pagespeed")
    expect(credenziale.provider_definition.key).to eq("pagespeed")

    # Si scrive in SQL apposta: il modello ora rifiuta di cambiare `provider`, ma una riga salvata
    # prima che un servizio venisse ritirato dal registro esiste comunque, e la pagina che la elenca
    # non deve esplodere.
    described_class.where(id: credenziale.id).update_all(provider: "servizio-ritirato")

    expect(credenziale.reload.provider_definition).to be_nil
  end

  it "sparisce con l'organizzazione" do
    create(:integration_credential, organization:)

    expect { organization.destroy }.to change(described_class, :count).by(-1)
  end
end
