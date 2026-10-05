# frozen_string_literal: true

require "rails_helper"

# CYRA-943 — answering a visitor by email, and the requests that say the same thing.
RSpec.describe "Member::HelpdeskRequests replies and similar requests", type: :request do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Shop", helpdesk_enabled: true) }
  let(:owner) { account_with_membership(:owner) }
  let(:colleague) { account_with_membership(:member, on_project: true) }
  let(:request_record) { create(:helpdesk_request, project: project, body: "I cannot pay by card 4411.", email: "anna@example.com") }

  def account_with_membership(role, on_project: false)
    create(:account).tap do |account|
      create(:membership, account:, organization: org, role:)
      create(:project_membership, account:, project:) if on_project
    end
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "answering" do
    it "saves the answer in the request, marks it answered and mails the visitor" do
      sign_in(owner)

      perform_enqueued_jobs do
        post member_helpdesk_request_reply_path(request_record), params: { body: "Fixed: please try again." }
      end

      expect(response).to redirect_to(member_helpdesk_request_path(request_record))
      expect(request_record.reload).to be_status_answered
      answer = request_record.messages.last
      expect(answer).to have_attributes(direction: "outbound", author: owner, body: "Fixed: please try again.")
      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ "anna@example.com" ])
      expect(mail.subject).to include("Shop")
      expect(mail.text_part.decoded).to include("Fixed: please try again.", "Do not reply")
    end

    it "shows the answer on the request page" do
      owner.update!(name: "Dana Agent")
      create(:helpdesk_message, request: request_record, direction: :outbound, author: owner, body: "Answer 9915")
      sign_in(owner)

      get member_helpdesk_request_path(request_record)

      expect(response.body).to include("Answer 9915", "Dana Agent", "helpdesk-reply-form")
    end

    it "sends nothing and offers no form when the request has no address" do
      request_record.update!(email: nil)
      sign_in(owner)

      get member_helpdesk_request_path(request_record)
      expect(response.body).to include("helpdesk-reply-nobody")
      expect(response.body).not_to include("helpdesk-reply-form")

      expect do
        post member_helpdesk_request_reply_path(request_record), params: { body: "Hello" }
      end.not_to have_enqueued_mail
      expect(request_record.reload).to be_status_received
    end

    it "refuses an empty answer" do
      sign_in(owner)

      expect do
        post member_helpdesk_request_reply_path(request_record), params: { body: " " }
      end.not_to have_enqueued_mail

      expect(request_record.messages.where(direction: :outbound)).to be_empty
    end

    it "stops at the cap of answers per request" do
      Helpdesk::Constants::REPLIES_PER_REQUEST_MAX.times do |index|
        create(:helpdesk_message, request: request_record, direction: :outbound, author: owner, body: "Answer #{index}")
      end
      sign_in(owner)

      expect do
        post member_helpdesk_request_reply_path(request_record), params: { body: "One more" }
      end.not_to have_enqueued_mail
      expect(flash[:alert]).to be_present
    end

    it "keeps the ticket link when an answered request was linked and unlinked" do
      ticket = create(:ticket, project: project)
      create(:helpdesk_message, request: request_record, direction: :outbound, author: owner, body: "Answer")
      request_record.update!(status: :linked, ticket: ticket)
      sign_in(owner)

      delete member_helpdesk_request_ticket_link_path(request_record)

      expect(request_record.reload).to be_status_answered
    end

    it "refuses who has no key" do
      sign_in(colleague)

      expect do
        post member_helpdesk_request_reply_path(request_record), params: { body: "Hello" }
      end.not_to have_enqueued_mail
    end

    it "writes the mail in the language of who answers" do
      owner.update!(locale: "it")
      message = create(:helpdesk_message, request: request_record, direction: :outbound, author: owner, body: "Risolto.")

      mail = Helpdesk::RepliesMailer.reply(message)

      expect(mail.subject).to include("Risposta alla tua richiesta")
      expect(mail.html_part.decoded).to include("Risolto.", "Non rispondere")
    end
  end

  describe "similar requests" do
    let(:version) { Ai::Configuration.current.embedding_version }

    def embed(request, vector)
      request.update_columns(embedding: vector, embedding_version: version)
    end

    it "shows the requests that say the same thing, and links them to the same ticket" do
      ticket = create(:ticket, project: project)
      request_record.update!(status: :linked, ticket: ticket)
      twin = create(:helpdesk_request, project: project, body: "Card payment fails 6621")
      far = create(:helpdesk_request, project: project, body: "Where is my invoice 6622")
      embed(request_record, basis_vector(0))
      embed(twin, basis_vector(0))
      embed(far, basis_vector(1))
      sign_in(owner)

      get member_helpdesk_request_path(request_record)
      expect(response.body).to include("1 similar request", "Card payment fails 6621", "helpdesk-similar-link")
      expect(response.body).not_to include("Where is my invoice 6622")

      post member_helpdesk_request_ticket_link_path(twin), params: { ticket_id: ticket.id, back_to: request_record.id }
      expect(response).to redirect_to(member_helpdesk_request_path(request_record))
      expect(twin.reload).to have_attributes(status: "linked", ticket: ticket)
    end

    it "leaves out other projects and discarded requests" do
      elsewhere = create(:helpdesk_request, project: create(:project, organization: org), body: "Elsewhere 6631")
      spam = create(:helpdesk_request, :discarded, project: project, body: "Spam 6632")
      [ request_record, elsewhere, spam ].each { |request| embed(request, basis_vector(0)) }
      sign_in(owner)

      get member_helpdesk_request_path(request_record)

      expect(response.body).not_to include("Elsewhere 6631", "Spam 6632", "helpdesk-similar")
    end

    it "shows nothing without AI: no embedding, no group, the page works" do
      create(:helpdesk_request, project: project, body: "Card payment fails 6641")
      sign_in(owner)

      get member_helpdesk_request_path(request_record)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("helpdesk-similar")
    end
  end
end
