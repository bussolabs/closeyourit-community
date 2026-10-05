# frozen_string_literal: true

require "rails_helper"

# CYRA-799 — il concern non tiene più gli elenchi: costruisce l'oggetto che li sa (`visible`) e lo
# lega alla richiesta. Qui si prova il filo — chi guarda davvero, il verdetto dei permessi, una sola
# istanza per richiesta — mentre gli elenchi per dominio sono provati sull'oggetto
# (spec/services/authorization/visible_scope_resources_spec.rb).
RSpec.describe VisibleResources do
  subject(:controller) do
    ctrl = Member::MembersController.new
    ctrl.set_request!(ActionDispatch::TestRequest.create)
    ctrl.set_response!(Member::MembersController.make_response!(ctrl.request))
    ctrl
  end

  let(:org) { create(:organization) }

  after { Current.reset }

  it "la pagina riceve UN oggetto solo, lo stesso per tutta la richiesta" do
    Current.account = create(:account)
    Current.organization = org

    expect(controller.send(:visible)).to be_a(Authorization::VisibleScope)
    expect(controller.send(:visible)).to be(controller.send(:visible))
  end

  # Il ramo che scavalca il linkage segue chi sta guardando DAVVERO: un god che impersona un member
  # continua a vedere tutto, e l'account impersonato da solo non lo aprirebbe.
  it "god via true_account vede tutti i progetti dell'org, anche impersonando un member" do
    impersonato = create(:account)
    create(:membership, account: impersonato, organization: org, role: :member)
    create(:project, organization: org)
    Current.true_account = create(:account, god: true)
    Current.account = impersonato
    Current.organization = org

    expect(controller.send(:visible).projects.count).to eq(1)
  end

  it "senza true_account resta lo scope dell'account (nessun ramo god acceso per sbaglio)" do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    create(:project, organization: org)
    Current.true_account = nil
    Current.account = account
    Current.organization = org

    expect(controller.send(:visible).projects).to be_empty
  end

  # Server e gruppi uptime sono org-level: il verdetto lo dà il gate del controller, e l'oggetto lo
  # riceve. Senza permesso l'elenco è vuoto anche se l'host esiste.
  describe "gli elenchi org-level chiedono il verdetto al gate" do
    before do
      create(:server_host, organization: org)
      Current.account = create(:account)
      Current.organization = org
    end

    it "senza il permesso l'elenco è vuoto" do
      allow(controller).to receive(:can?).and_return(false)

      expect(controller.send(:visible).servers).to be_empty
    end

    it "col permesso si vedono gli host dell'org" do
      allow(controller).to receive(:can?).and_return(true)

      expect(controller.send(:visible).servers.count).to eq(1)
    end
  end
end
