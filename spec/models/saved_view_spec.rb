# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedView, type: :model do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  describe "sanitizzazione filtri (per risorsa)" do
    it "tiene solo le chiavi ammesse dalla risorsa e scarta le altre (anti-injection)" do
      view = create(:saved_view, account: account, organization: organization, resource_type: "tickets",
                                 filters: { "status_id" => [ "a" ], "evil" => "x", "q" => "login" })
      expect(view.filters.keys).to contain_exactly("status_id", "q")
    end

    it "le chiavi ammesse cambiano con la risorsa (error_groups non ha kind)" do
      view = create(:saved_view, account: account, organization: organization, resource_type: "error_groups",
                                 filters: { "level" => [ "error" ], "kind" => [ "bug" ], "q" => "boom" })
      expect(view.filters.keys).to contain_exactly("level", "q")
    end

    it "scarta gli array svuotati e le stringhe vuote" do
      view = create(:saved_view, account: account, organization: organization,
                                 filters: { "status_id" => [ "", nil ], "q" => "  " })
      expect(view.filters).to eq({})
    end

    it "preserva gli array dei multi-select" do
      view = create(:saved_view, account: account, organization: organization,
                                 filters: { "kind" => %w[bug story] })
      expect(view.filters["kind"]).to eq(%w[bug story])
    end

    it "filters non-Hash (nil) → normalizzato a {} senza crash (ramo else)" do
      view = build(:saved_view, account: account, organization: organization,
                                resource_type: "tickets", filters: nil)
      view.valid?
      expect(view.filters).to eq({})
    end
  end

  describe "validazioni" do
    it "richiede un nome" do
      expect(build(:saved_view, account: account, organization: organization, name: "  ")).not_to be_valid
    end

    it "richiede un resource_type noto" do
      expect(build(:saved_view, account: account, organization: organization, resource_type: "bogus")).not_to be_valid
      expect(build(:saved_view, account: account, organization: organization, resource_type: nil)).not_to be_valid
    end

    it "nome unico per (account, organizzazione, risorsa)" do
      create(:saved_view, account: account, organization: organization, resource_type: "tickets", name: "Mine")
      dup = build(:saved_view, account: account, organization: organization, resource_type: "tickets", name: "Mine")
      expect(dup).not_to be_valid
    end

    it "lo stesso nome è ammesso su risorse diverse" do
      create(:saved_view, account: account, organization: organization, resource_type: "tickets", name: "Mine")
      other = build(:saved_view, account: account, organization: organization, resource_type: "error_groups", name: "Mine")
      expect(other).to be_valid
    end

    it "lo stesso nome è ammesso per account diversi (isolamento)" do
      create(:saved_view, account: account, organization: organization, name: "Mine")
      other = build(:saved_view, account: create(:account), organization: organization, name: "Mine")
      expect(other).to be_valid
    end
  end

  describe ".for / .for_resource" do
    it ".for ritorna solo le viste dell'account nell'org" do
      mine = create(:saved_view, account: account, organization: organization)
      create(:saved_view, account: create(:account), organization: organization)
      expect(described_class.for(account: account, organization: organization)).to contain_exactly(mine)
    end

    it ".for_resource filtra per risorsa" do
      tickets = create(:saved_view, account: account, organization: organization, resource_type: "tickets")
      create(:saved_view, account: account, organization: organization, resource_type: "error_groups")
      expect(described_class.for_resource("tickets")).to contain_exactly(tickets)
    end
  end

  describe "coerenza con INDEX_HELPERS del controller (guard anti-regressione)" do
    # Ogni risorsa accettata dalla validazione DEVE avere un path helper nel controller, altrimenti
    # save/destroy vanno in KeyError → 500 (CYRA-224: "ideas" era in FILTER_KEYS ma non in INDEX_HELPERS).
    # Aggiungere una risorsa a una sola delle due mappe fa fallire qui, non in produzione.
    it "ogni risorsa di FILTER_KEYS ha un path helper in INDEX_HELPERS" do
      expect(SavedView::FILTER_KEYS.keys - Member::SavedViewsController::INDEX_HELPERS.keys).to be_empty
    end
  end
end
