# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Ideas::Conversions", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:author) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project, author: author, title: "Dark mode") }

  before do
    Types::InstallDefaults.call(organization: org)
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: author, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    create(:project_membership, account: author, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET new (preview)" do
    it "l'autore vede il form con fallback titolo/corpo dell'idea" do
      sign_in(author)
      get new_member_idea_conversion_path(idea)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Dark mode", "idea-convert-form")
    end

    it "owner vede il form per un'idea altrui" do
      sign_in(owner)
      get new_member_idea_conversion_path(idea)
      expect(response).to have_http_status(:ok)
    end

    it "membro NON autore senza ideas.convert → redirect (denied)" do
      sign_in(member)
      get new_member_idea_conversion_path(idea)
      expect(response).to have_http_status(:redirect)
    end

    it "idea già convertita → redirect alla show con alert" do
      converted = create(:idea, :converted, organization: org, project: project, author: author)
      sign_in(author)
      get new_member_idea_conversion_path(converted)
      expect(response).to redirect_to(member_idea_path(converted))
      expect(flash[:alert]).to be_present
    end

    it "il form offre tutti i tipi su qualunque progetto" do
      plain_project = create(:project, organization: org)
      plain_idea = create(:idea, organization: org, project: plain_project, author: owner)
      sign_in(owner)
      get new_member_idea_conversion_path(plain_idea)

      expect(response.body).to include("idea-convert-kind-bug", "idea-convert-kind-story",
                                       "idea-convert-kind-task", "idea-convert-kind-epic")
    end
  end

  describe "POST create" do
    let(:valid_params) do
      { title: "Dark mode per la dashboard", description: "Sintesi rivista", kind: "story" }
    end

    it "crea il ticket, congela l'idea e reindirizza al ticket" do
      sign_in(author)
      expect do
        post member_idea_conversion_path(idea), params: valid_params
      end.to change(Ticketing::Ticket, :count).by(1)

      idea.reload
      expect(idea).to be_status_converted
      expect(idea.ticket).to be_present
      expect(idea.ticket.title).to eq("Dark mode per la dashboard")
      expect(response).to redirect_to(member_ticket_path(idea.ticket))
    end

    it "validazione ticket fallita (description vuota su feature) → 422, idea resta aperta" do
      sign_in(author)
      expect do
        post member_idea_conversion_path(idea), params: valid_params.merge(description: "")
      end.not_to change(Ticketing::Ticket, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(idea.reload).to be_status_open
    end

    it "idea già convertita → redirect con alert, nessun secondo ticket" do
      converted = create(:idea, :converted, organization: org, project: project, author: author)
      sign_in(author)
      expect do
        post member_idea_conversion_path(converted), params: valid_params
      end.not_to change(Ticketing::Ticket, :count)
      expect(response).to redirect_to(member_idea_path(converted))
    end

    it "membro NON autore senza ideas.convert → nessun ticket" do
      sign_in(member)
      expect do
        post member_idea_conversion_path(idea), params: valid_params
      end.not_to change(Ticketing::Ticket, :count)
      expect(idea.reload).to be_status_open
    end
  end
end
