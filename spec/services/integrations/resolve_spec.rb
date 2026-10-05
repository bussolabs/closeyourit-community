# frozen_string_literal: true

require "rails_helper"

# CYRA-544 — l'unica porta da cui il codice chiede la credenziale di un'organizzazione.
#
# Il controllo che conta è il PRIMO: l'organizzazione è obbligatoria. Con una lettura implicita da
# `Current`, un job che dimentica il contesto vedrebbe «nessuna chiave» e spegnerebbe la funzione in
# silenzio — che è esattamente il modo in cui in questo prodotto gli embedding sono rimasti spenti
# per un giorno e mezzo senza che nessuno se ne accorgesse.
RSpec.describe Integrations::Resolve do
  let(:organization) { create(:organization) }

  describe "l'organizzazione è obbligatoria" do
    it "solleva invece di rispondere «non collegato»" do
      expect { described_class.api_key(organization: nil, provider: "pagespeed") }
        .to raise_error(ArgumentError, /organization/)
      expect { described_class.connected?(organization: nil, provider: "pagespeed") }
        .to raise_error(ArgumentError, /organization/)
      expect { described_class.connected_providers(organization: nil) }
        .to raise_error(ArgumentError, /organization/)
    end

    it "un servizio che non conosciamo è un errore di programmazione, non un «non collegato»" do
      expect { described_class.api_key(organization:, provider: "inventato") }
        .to raise_error(ArgumentError, /inventato/)
    end
  end

  describe ".api_key" do
    it "restituisce la chiave dell'organizzazione che l'ha collegata" do
      create(:integration_credential, organization:, provider: "pagespeed", api_key: "AIza-la-mia")

      expect(described_class.api_key(organization:, provider: "pagespeed")).to eq("AIza-la-mia")
    end

    it "accetta anche il solo id: i job hanno spesso quello, e ricaricare il record sarebbe una query per niente" do
      create(:integration_credential, organization:, provider: "pagespeed", api_key: "AIza-la-mia")

      expect(described_class.api_key(organization: organization.id, provider: "pagespeed")).to eq("AIza-la-mia")
    end

    it "è nil se quell'organizzazione non ha collegato quel servizio" do
      expect(described_class.api_key(organization:, provider: "pagespeed")).to be_nil
    end

    # La chiave di un'organizzazione non deve MAI finire nelle mani di un'altra: è il punto di tutta
    # la lavorazione.
    it "non vede la chiave di un'altra organizzazione" do
      altra = create(:organization)
      create(:integration_credential, organization: altra, provider: "pagespeed", api_key: "AIza-di-altri")

      expect(described_class.api_key(organization:, provider: "pagespeed")).to be_nil
    end

    # Una chiave che ieri non rispondeva può rispondere oggi. La verifica serve a DIRLO in pagina,
    # non a decidere al posto del fornitore.
    it "restituisce la chiave anche se l'ultima verifica era fallita" do
      create(:integration_credential, :broken, organization:, provider: "pagespeed", api_key: "AIza-forse")

      expect(described_class.api_key(organization:, provider: "pagespeed")).to eq("AIza-forse")
    end
  end

  describe ".connected?" do
    it "dice se c'è, senza decifrare niente" do
      create(:integration_credential, organization:, provider: "pagespeed")

      expect(described_class).to be_connected(organization:, provider: "pagespeed")
      expect(described_class).not_to be_connected(organization: create(:organization), provider: "pagespeed")
    end
  end

  describe ".connected_providers" do
    it "elenca cosa ha collegato, in una query e senza decifrare" do
      create(:integration_credential, organization:, provider: "pagespeed")

      expect(described_class.connected_providers(organization:)).to eq(Set["pagespeed"])
    end
  end
end
