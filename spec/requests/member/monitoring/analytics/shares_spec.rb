# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Analytics::Shares", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  let(:project) { create(:project, organization: org, analytics_enabled: true).tap { |p| p.platforms << web } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "POST create" do
    it "crea un link pubblico e reindirizza alla dashboard" do
      expect do
        post member_monitoring_analytics_share_path(project_id: project.id), params: { confirm: "1" }
      end.to change(Analytics::Link, :count).by(1)

      expect(response).to redirect_to(member_monitoring_analytics_path(project_id: project.id))
    end

    it "BOLA: progetto di un'altra org → 404" do
      other = create(:organization)
      Types::InstallDefaults.call(organization: other)
      foreign = create(:project, organization: other, analytics_enabled: true)
        .tap { |p| p.platforms << Types::Platform.find_by!(organization: other, code: "web") }

      post member_monitoring_analytics_share_path(project_id: foreign.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy" do
    it "revoca il link attivo del progetto" do
      create(:analytics_link, project:)
      expect do
        delete member_monitoring_analytics_share_path(project_id: project.id), params: { confirm: "1" }
      end.to change(Analytics::Link, :count).by(-1)

      expect(response).to redirect_to(member_monitoring_analytics_path(project_id: project.id))
    end
  end

  # CYRA-697 — pubblicare su internet la dashboard di traffico era ungated: l'unico before_action era
  # un set_project anti-BOLA, che dice QUALE progetto, non SE puoi. Chiunque vedesse un progetto che
  # raccoglie statistiche — cliente esterno compreso — lo pubblicava con una sola richiesta, e in
  # banca dati non restava scritto chi fosse stato.
  describe "chiave di permesso e autore (CYRA-697)" do
    let(:cliente) { create(:account) }

    def entra_come_cliente
      create(:membership, account: cliente, organization: org, role: :customer)
      create(:project_membership, account: cliente, project: project)
      post logout_path
      post login_path, params: { email: cliente.email, password: "Secret123!" }
    end

    it "un cliente esterno che vede il progetto NON pubblica il link" do
      entra_come_cliente

      expect do
        post member_monitoring_analytics_share_path(project_id: project.id)
      end.not_to change(Analytics::Link, :count)

      expect(response).to redirect_to(root_path)
    end

    it "un cliente esterno non revoca il link di qualcun altro" do
      create(:analytics_link, project:)
      entra_come_cliente

      expect do
        delete member_monitoring_analytics_share_path(project_id: project.id)
      end.not_to change(Analytics::Link, :count)
    end

    it "il link salva chi lo ha creato" do
      post member_monitoring_analytics_share_path(project_id: project.id), params: { confirm: "1" }

      expect(Analytics::Link.sole.created_by).to eq(owner)
    end

    it "la dashboard mostra chi ha pubblicato il link" do
      post member_monitoring_analytics_share_path(project_id: project.id), params: { confirm: "1" }

      get member_monitoring_analytics_path(project_id: project.id)
      pannello = Nokogiri::HTML(response.body).at_css("[data-test='analytics-share']")
      expect(pannello.text).to include(owner.name)
    end
  end
end
