# frozen_string_literal: true

require "rails_helper"

# Come la pagina dei servizi collegabili legge lo stato di una credenziale e i testi che le stanno
# intorno (CYRA-545).
RSpec.describe IntegrationsHelper, type: :helper do
  let(:organization) { create(:organization) }

  # CYRA-545 — quattro stati e non tre: «collegato ma mai provato» non è «collegato» (nessuno ha
  # ancora detto che quella chiave funzioni) e non è «rotto» (nessuno ha detto che non funzioni).
  # Confonderli dipingerebbe di verde una credenziale che non è mai stata messa alla prova.
  describe "#integration_state" do
    it "senza credenziale il servizio non è collegato" do
      expect(helper.integration_state(nil)).to eq(:missing)
    end

    it "con l'ultima prova riuscita è collegato" do
      credential = create(:integration_credential, :verified, organization:)

      expect(helper.integration_state(credential)).to eq(:connected)
    end

    it "con l'ultima prova fallita è da controllare" do
      credential = create(:integration_credential, :broken, organization:)

      expect(helper.integration_state(credential)).to eq(:broken)
    end

    it "appena incollata, e non ancora provata, non è né collegata né rotta" do
      credential = create(:integration_credential, organization:)

      expect(helper.integration_state(credential)).to eq(:unverified)
    end
  end

  describe "#integration_tone" do
    it "traduce il colore del registro in classi vere" do
      expect(helper.integration_tone("violet")).to include("text-violet-600")
    end

    # Le classi sono letterali proprio perché Tailwind purga le interpolate: un colore fuori mappa
    # deve ricadere sul neutro, non lasciare un riquadro senza sfondo.
    it "un colore che non conosciamo ricade sul neutro" do
      expect(helper.integration_tone("fucsia")).to eq(IntegrationsHelper::INTEGRATION_TONE_FALLBACK)
    end
  end

  describe "#integration_features" do
    it "elenca le funzioni che quel servizio accende, coi nomi che si leggono in pagina" do
      provider = Integrations::Providers.find("pagespeed")

      expect(helper.integration_features(provider)).to eq([ I18n.t("integrations.features.site_speed") ])
    end
  end
end
