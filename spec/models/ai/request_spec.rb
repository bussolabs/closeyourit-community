# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Request, type: :model do
  describe "validazioni" do
    it "è valida con kind ammesso" do
      expect(build(:ai_request, kind: "ticket_analyze")).to be_valid
    end

    it "rifiuta kind fuori allow-list" do
      request = build(:ai_request, kind: "qualcosa")
      expect(request).not_to be_valid
      expect(request.errors[:kind]).to be_present
    end

    it "rifiuta kind blank" do
      expect(build(:ai_request, kind: "")).not_to be_valid
    end
  end

  # CYRA-765 — la mappa dice quale servizio COLLEGATO DALL'ORGANIZZAZIONE serve a ciascuna richiesta,
  # ed è vuota: l'AI generativa la offre il sistema, quindi nessun kind pretende un collegamento e il
  # gate di AiEnqueueing lascia passare tutto. Non è un valore persistito: `ai_requests` non ha una
  # colonna provider, quindi svuotarla non tocca nessuna riga già scritta.
  describe ".provider_for" do
    it "ogni kind mappato esiste davvero fra i kind ammessi" do
      expect(described_class::PROVIDERS.keys - described_class::KINDS).to be_empty
    end

    it "ogni servizio nominato esiste nel registro delle integrazioni" do
      expect(described_class::PROVIDERS.values.uniq.all? { |p| Integrations::Providers.known?(p) }).to be(true)
    end

    it "nessun kind pretende più un servizio collegato" do
      described_class::KINDS.each do |kind|
        expect(described_class.provider_for(kind)).to be_nil, "#{kind}: pretende ancora un collegamento"
      end
    end
  end

  describe ".for" do
    it "restituisce solo le richieste dell'account nell'org e esclude le altrui" do
      mine  = create(:ai_request)
      other = create(:ai_request)

      scope = described_class.for(account: mine.account, organization: mine.organization)
      expect(scope).to include(mine)
      expect(scope).not_to include(other)
    end
  end

  describe ".stale" do
    it "include solo le richieste oltre la retention (confine ±1s)" do
      travel_to Time.current do
        old_one   = create(:ai_request, created_at: Ai::Constants::REQUESTS_RETENTION.ago - 1.second)
        limit_one = create(:ai_request, created_at: Ai::Constants::REQUESTS_RETENTION.ago + 1.second)

        expect(described_class.stale).to include(old_one)
        expect(described_class.stale).not_to include(limit_one)
      end
    end
  end

  describe "#finish_ok!" do
    it "porta a done con payload" do
      request = create(:ai_request)
      request.finish_ok!({ "summary" => "ok" })
      expect(request.reload).to be_status_done
      expect(request.payload).to eq({ "summary" => "ok" })
    end
  end

  describe "#finish_err!" do
    it "porta a failed con codice e messaggio" do
      request = create(:ai_request)
      request.finish_err!(code: "R502-AI-001", message: "gateway giù")
      expect(request.reload).to be_status_failed
      expect(request.error_code).to eq("R502-AI-001")
      expect(request.error_message).to eq("gateway giù")
    end
  end
end
