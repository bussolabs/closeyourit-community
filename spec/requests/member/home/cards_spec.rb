# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Home::Cards", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)

  def piano(planned_at: 2.days.ago, project: self.project)
    ticket = create(:ticket, organization: org, project: project)
    create(:agent_workflow, ticket:, planned_at:)
  end

  def codice_mostrato
    get root_path
    html.at_css("[data-test='decision-code']")&.text
  end

  describe "POST skip" do
    it "mette da parte la decisione e mostra la successiva" do
      prima = piano(planned_at: 5.days.ago)
      seconda = piano(planned_at: 2.days.ago)
      sign_in(owner)

      post member_home_card_skip_path, params: { item: "agent_plan:#{prima.id}" }

      expect(response).to redirect_to(root_path)
      expect(codice_mostrato).to eq(seconda.ticket.code)
    end

    it "non decide niente: la lavorazione resta dov'era" do
      workflow = piano
      sign_in(owner)

      post member_home_card_skip_path, params: { item: "agent_plan:#{workflow.id}" }

      expect(workflow.reload.planned_at).to be_present
      expect(workflow.reload.approved_at).to be_nil
    end

    it "non scrive niente nel database" do
      workflow = piano
      sign_in(owner)

      expect { post member_home_card_skip_path, params: { item: "agent_plan:#{workflow.id}" } }
        .not_to change(Home::Deferral, :count)
    end

    it "rifiuta una decisione che non mi compete, senza dire che esiste" do
      altrove = create(:project, organization: create(:organization))
      workflow = create(:agent_workflow,
                        ticket: create(:ticket, organization: altrove.organization, project: altrove),
                        planned_at: 1.day.ago)
      sign_in(owner)

      post member_home_card_skip_path, params: { item: "agent_plan:#{workflow.id}" }

      expect(response).to have_http_status(:not_found)
    end

    it "rifiuta una chiave inventata" do
      sign_in(owner)

      post member_home_card_skip_path, params: { item: "agent_plan:#{SecureRandom.uuid}" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST defer" do
    it "rimanda a domani e lo scrive, così vale anche altrove" do
      workflow = piano
      sign_in(owner)

      expect { post member_home_card_defer_path, params: { item: "agent_plan:#{workflow.id}" } }
        .to change(Home::Deferral, :count).by(1)

      expect(response).to redirect_to(root_path)
      expect(Home::Deferral.sole.card_key).to eq("agent_plan:#{workflow.id}")
    end

    it "la decisione rimandata sparisce dalla home, e il conteggio dei rimandi la ricorda" do
      workflow = piano
      sign_in(owner)

      post member_home_card_defer_path, params: { item: "agent_plan:#{workflow.id}" }
      get root_path

      expect(html.at_css("[data-test='decision-subject']")).to be_nil
      expect(html.at_css("[data-test='home-count-deferred']").text).to include("1")
    end

    it "non decide niente: la lavorazione resta dov'era" do
      workflow = piano
      sign_in(owner)

      post member_home_card_defer_path, params: { item: "agent_plan:#{workflow.id}" }

      expect(workflow.reload.approved_at).to be_nil
    end

    it "rifiuta una decisione che non mi compete, senza scrivere niente" do
      altrove = create(:project, organization: create(:organization))
      workflow = create(:agent_workflow,
                        ticket: create(:ticket, organization: altrove.organization, project: altrove),
                        planned_at: 1.day.ago)
      sign_in(owner)

      expect { post member_home_card_defer_path, params: { item: "agent_plan:#{workflow.id}" } }
        .not_to change(Home::Deferral, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST back" do
    it "riprende l'ultima messa da parte" do
      prima = piano(planned_at: 5.days.ago)
      piano(planned_at: 2.days.ago)
      sign_in(owner)
      post member_home_card_skip_path, params: { item: "agent_plan:#{prima.id}" }

      post member_home_card_back_path

      expect(response).to redirect_to(root_path)
      expect(codice_mostrato).to eq(prima.ticket.code)
    end

    it "senza niente da riprendere lo dice, invece di non fare nulla in silenzio" do
      piano
      sign_in(owner)

      post member_home_card_back_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to be_present
    end
  end
end
