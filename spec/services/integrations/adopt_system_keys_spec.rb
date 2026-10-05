# frozen_string_literal: true

require "rails_helper"

RSpec.describe Integrations::AdoptSystemKeys, type: :service do
  let(:organization) { create(:organization) }
  let(:altra) { create(:organization) }
  # Dal CYRA-765 c'è una sola chiave da adottare: quella dell'AI non è più di un'organizzazione.
  let(:env) { { "GOOGLE_PAGESPEED_API_KEY" => "AIza-di-sistema" } }

  # Scenario 1 del ticket, ed è il motivo per cui questa lavorazione esiste: copiare la chiave
  # dell'operatore in tutte le organizzazioni vorrebbe dire continuare a far consumare la sua quota a
  # tutti — cioè lasciare le cose com'erano, con un'aria di novità.
  describe "la chiave di sistema va a UNA sola organizzazione" do
    it "la scrive sull'organizzazione designata" do
      described_class.call(organization:, env:)

      collegati = Integrations::Credential.where(organization:).pluck(:provider)
      expect(collegati).to match_array(%w[pagespeed])
    end

    it "non ne lascia una sola copia nelle altre organizzazioni" do
      altra

      described_class.call(organization:, env:)

      expect(Integrations::Credential.where(organization: altra)).to be_empty
    end

    it "restituisce i servizi adottati, in modo che chi la esegue veda cos'è successo" do
      result = described_class.call(organization:, env:)

      expect(result).to be_ok
      expect(result.value).to match_array(%w[pagespeed])
    end
  end

  describe "cosa non fa" do
    it "senza organizzazione non prova nemmeno: una chiave senza padrone non si scrive da nessuna parte" do
      expect { described_class.call(organization: nil, env:) }.to raise_error(ArgumentError)
    end

    it "una variabile assente non produce nessuna credenziale" do
      described_class.call(organization:, env: {})

      expect(Integrations::Credential.where(organization:)).to be_empty
    end

    it "una variabile vuota non è una chiave" do
      described_class.call(organization:, env: { "GOOGLE_PAGESPEED_API_KEY" => "   " })

      expect(Integrations::Credential.where(organization:)).to be_empty
    end

    # Il passaggio si esegue una volta sola, ma un secondo giro deve essere innocuo: se qualcuno ha
    # già collegato la propria chiave, quella resta. Sovrascriverla rimetterebbe la chiave
    # dell'operatore al posto di una chiave che qualcuno ha scelto apposta.
    it "non sostituisce una chiave che l'organizzazione ha già collegato" do
      esistente = create(:integration_credential, organization:, provider: "pagespeed", api_key: "AIza-sua")

      described_class.call(organization:, env:)

      expect(esistente.reload.api_key).to eq("AIza-sua")
    end

    it "eseguirlo due volte non crea doppioni" do
      described_class.call(organization:, env:)

      expect { described_class.call(organization:, env:) }
        .not_to change(Integrations::Credential, :count)
    end
  end

  # La prova costa una chiamata di rete per servizio: farla dentro una migration vorrebbe dire un
  # rilascio che si blocca perché Google è lento. La fa il giro giornaliero, entro il giorno dopo.
  it "la credenziale adottata nasce non ancora provata, non «verificata»" do
    described_class.call(organization:, env:)

    credenziale = Integrations::Credential.find_by(organization:, provider: "pagespeed")
    expect(credenziale.verified_at).to be_nil
    expect(credenziale).not_to be_verified
    expect(credenziale).not_to be_broken
  end

  it "la chiave adottata è quella che c'era nell'ambiente" do
    described_class.call(organization:, env:)

    expect(Integrations::Credential.find_by(organization:, provider: "pagespeed").api_key).to eq("AIza-di-sistema")
  end

  # Una variabile che nomina un servizio non presente nel registro creerebbe una credenziale che
  # nessuno sa più verificare né usare: la validazione del modello la rifiuterebbe, ma il guasto
  # arriverebbe in faccia a chi esegue la migrazione, non a chi ha scritto la mappa.
  it "adotta soltanto servizi che il registro conosce" do
    expect(described_class::ENV_KEYS.keys).to all(satisfy { |key| Integrations::Providers.known?(key) })
  end
end
