# frozen_string_literal: true

require "rails_helper"

# CYRA-1162 — the request to recommend the app on the ticket page: after an error an agent resolved,
# or past the closed tickets threshold. Once per moment, never for an impersonation, never on the page
# a save led back to, never next to an approval waiting for a decision.
RSpec.describe "Member ticket referral prompt", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:done_status) { create(:ticket_status, :done, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, status: done_status) }
  let(:person) { create(:account) }
  let(:role) { :owner }

  before do
    create(:membership, organization:, account: person, role:)
    create(:project_membership, project:, account: person)
  end

  # The landing page after login carries its «signed in» notice: following it spends that flash, so
  # the next page is one the person simply opened.
  def sign_in(account = person)
    post login_path, params: { email: account.email, password: "Secret123!" }
    follow_redirect!
  end

  def agent_resolved_error!
    create(:error_group, project:, ticket:)
    create(:agent_workflow, :closer_staging_completed, ticket:).update_columns(completed_at: 1.hour.ago)
  end

  def prompt_on_page
    get member_ticket_path(ticket)
    Nokogiri::HTML(response.body).at_css("aside[data-test='referral-prompt']")
  end

  def shown_count = Accounts::ReferralPrompt.where(account: person).pick(:shown_count) || 0

  context "when an agent has just resolved an error of the organization" do
    before do
      agent_resolved_error!
      sign_in
    end

    it "shows the prompt once, with the invite and the star" do
      notice = prompt_on_page

      expect(notice).to be_present
      expect(notice.at_css("[data-test='referral-prompt-invite']")["href"]).to eq(new_member_invitation_path)
      expect(notice.at_css("[data-test='referral-prompt-star']")["href"]).to eq(Accounts::ReferralPrompt::STAR_URL)
      expect(prompt_on_page).to be_nil
      expect(shown_count).to eq(1)
    end

    context "without the permission to invite" do
      let(:role) { :member }

      it "offers only the star" do
        notice = prompt_on_page

        expect(notice.at_css("[data-test='referral-prompt-star']")).to be_present
        expect(notice.at_css("[data-test='referral-prompt-invite']")).to be_nil
      end
    end
  end

  it "appears once the closed tickets reach the threshold, on a page opened afterwards" do
    Accounts::ReferralPrompt.create!(account: person, closed_tickets_count: 9)
    open_ticket = create(:ticket, organization:, project:, status: create(:ticket_status, organization:))
    sign_in

    patch status_member_ticket_path(open_ticket), params: { status_id: done_status.id, inline: 1 }
    follow_redirect!
    expect(response.body).not_to include("data-test=\"referral-prompt\"")

    expect(prompt_on_page).to be_present
    expect(shown_count).to eq(1)
  end

  it "stays away while an approval waits for a decision" do
    Accounts::ReferralPrompt.create!(account: person, closed_tickets_count: 10)
    ticket.update!(status: create(:ticket_status, :in_review, organization:))
    sign_in

    expect(prompt_on_page).to be_nil
    expect(shown_count).to eq(0)
  end

  it "does not appear, nor spend a show, when a manager stands in for the person" do
    agent_resolved_error!
    god = create(:account, god: true)
    sign_in_god(god)
    start_impersonation_as(god, account_id: person.id)
    follow_redirect!

    expect(prompt_on_page).to be_nil
    expect(shown_count).to eq(0)
  end

  describe "the person's choice" do
    before do
      Accounts::ReferralPrompt.create!(account: person, closed_tickets_count: 10)
      sign_in
    end

    it "«Later» raises the threshold and the prompt waits for it" do
      patch member_referral_prompt_path(choice: "later")

      expect(response).to have_http_status(:see_other)
      expect(person.reload.referral_prompt.next_threshold).to eq(50)
      expect(prompt_on_page).to be_nil
    end

    it "«No, thanks» turns it off past any threshold" do
      patch member_referral_prompt_path(choice: "never")
      person.referral_prompt.update!(closed_tickets_count: 1000)

      expect(prompt_on_page).to be_nil
      expect(person.reload.referral_prompt.declined_at).to be_present
    end

    it "refuses an unknown choice" do
      patch member_referral_prompt_path(choice: "maybe")

      expect(response).to have_http_status(:unprocessable_content)
      expect(person.reload.referral_prompt.postponed_at).to be_nil
    end
  end
end
