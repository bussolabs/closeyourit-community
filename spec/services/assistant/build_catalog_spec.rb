# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::BuildCatalog do
  let(:organization) { create(:organization) }

  def catalog_for(account)
    described_class.call(account: account, organization: organization)
  end

  def member_with(role)
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: role) }
  end

  describe "filtro RBAC" do
    it "a un owner espone TUTTE le funzioni del registro (bypassa i gate)" do
      expect(catalog_for(member_with(:owner)).map(&:key)).to match_array(described_class::FUNCTIONS.map { |f| f[:key] })
    end

    it "a un owner include le funzioni gated dai permessi (Membri, Ruoli, Organizzazione, Server)" do
      keys = catalog_for(member_with(:owner)).map(&:key)
      expect(keys).to include("members", "roles", "organization", "servers")
    end

    it "a un membro senza permessi include le funzioni baseline (Ticket, Idee, Knowledge)" do
      keys = catalog_for(member_with(:member)).map(&:key)
      expect(keys).to include("tickets", "ideas", "knowledge")
    end

    it "a un membro senza permessi ESCLUDE le funzioni gated (Membri, Ruoli, Organizzazione, Server)" do
      keys = catalog_for(member_with(:member)).map(&:key)
      expect(keys).not_to include("members", "roles", "organization", "servers")
    end

    it "include una funzione .view anche col SOLO permesso .manage (manage-implies-view come i controller)" do
      # servers/members/platforms/environments/agents consentono la lettura anche col solo .manage
      # (gate `require .view unless can?(.manage)` oppure `return if can_view_*?` = view || manage):
      # chi ha .manage apre comunque la pagina, quindi deve trovarla nel catalogo.
      resolver = instance_double(Authorization::Resolver)
      allow(resolver).to receive(:can?).and_return(false)
      allow(resolver).to receive(:can?).with("platforms.manage").and_return(true)
      allow(resolver).to receive(:can?).with("agents.manage").and_return(true)

      keys = described_class.call(account: member_with(:member), organization: organization, resolver: resolver).map(&:key)
      expect(keys).to include("platforms", "agents")
    end
  end

  describe "integrità delle voci" do
    subject(:catalog) { catalog_for(member_with(:owner)) }

    it "ogni funzione ha un'etichetta e una descrizione tradotte (niente 'translation missing')" do
      catalog.each do |f|
        expect(f.label).to be_present
        expect(f.label).not_to match(/translation missing/i)
        expect(f.description).to be_present
        expect(f.description).not_to match(/translation missing/i)
      end
    end

    it "ogni path è una rotta GET reale (i link non sono allucinabili)" do
      catalog.each do |f|
        expect { Rails.application.routes.recognize_path(f.path, method: :get) }
          .not_to raise_error, "path non valido per '#{f.key}': #{f.path}"
      end
    end
  end
end
