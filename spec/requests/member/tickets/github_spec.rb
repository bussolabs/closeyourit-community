# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets::Github", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:owner_m) { create(:membership, account: owner, organization: org, role: :owner) }
  let(:project) { create(:project, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project:) }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization: org))
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def stub_client(**methods)
    allow(Github::Client).to receive(:new).and_return(instance_double(Github::Client, **methods))
  end

  before { sign_in(owner) }

  describe "POST branch" do
    it "crea il branch e reindirizza al ticket" do
      stub_client(ref: { "object" => { "sha" => "abc" } }, create_ref: {})

      post branch_member_ticket_github_path(ticket)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket.github_branches).to exist
    end

    it "in errore reindirizza col messaggio, nessun branch" do
      client = instance_double(Github::Client, ref: { "object" => { "sha" => "abc" } })
      allow(client).to receive(:create_ref).and_raise(Github::Client::Error.new("boom", code: "R502-GITHUB-001"))
      allow(Github::Client).to receive(:new).and_return(client)

      post branch_member_ticket_github_path(ticket)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket.github_branches).not_to exist
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      outsider = create(:account)
      create(:membership, account: outsider, organization: create(:organization), role: :owner)
      sign_in(outsider)

      post branch_member_ticket_github_path(ticket)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST pull_request" do
    it "apre la PR e reindirizza al ticket" do
      create(:github_branch, repository:, ticket:, name: "#{ticket.code}-fix")
      stub_client(create_pull: {
                    "number" => 3, "html_url" => "https://github.com/bussolabs/app/pull/3",
                    "id" => 1, "user" => { "login" => "bot" }
                  })

      post pull_request_member_ticket_github_path(ticket)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket.github_pull_requests).to exist
    end

    it "senza branch del ticket → reindirizza col messaggio, nessuna PR" do
      post pull_request_member_ticket_github_path(ticket)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket.github_pull_requests).not_to exist
    end
  end

  # CYRA-1055 — «Pubblica su GitHub»: the ticket becomes an issue and stays aligned with it.
  describe "POST issue" do
    it "publishes the ticket as an issue and links them" do
      repository.update!(issue_sync: :all_issues)
      stub_client(create_issue: {
                    "number" => 12, "id" => 1200, "node_id" => "I_12", "title" => ticket.title, "body" => "",
                    "html_url" => "https://github.com/#{repository.full_name}/issues/12", "state" => "open",
                    "labels" => [], "assignees" => [], "user" => { "login" => "bot" }
                  })

      post issue_member_ticket_github_path(ticket)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket.reload.github_issue.number).to eq(12)
    end

    it "with the sync off nothing is published" do
      post issue_member_ticket_github_path(ticket)

      expect(response).to redirect_to(member_ticket_path(ticket))
      expect(ticket.reload.github_issue).to be_nil
    end
  end
end
