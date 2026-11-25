# frozen_string_literal: true

require "rails_helper"

# CYRA-1159 — each of the five moments ticks its step where the fact is born, from page and CLI alike.
RSpec.describe "Recording the first steps" do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:project) { create(:project, organization: organization) }

  def steps = organization.first_steps.reload.pluck(:step)

  describe "first error" do
    def ingest(type)
      Errors::Ingest::Record.call(project:, payload: {
        "event_id" => SecureRandom.hex(16), "exception" => { "values" => [ { "type" => type, "value" => "boom" } ] }
      })
    end

    it "is written once, on the first new group, however many times the error arrives" do
      ingest("TimeoutError")
      first_day = organization.first_steps.find_by!(step: "first_error").reached_at
      travel 1.day do
        3.times { ingest("TimeoutError") }
        ingest("OtherError")
      end

      expect(project.error_groups.count).to eq(2)
      expect(organization.first_steps.where(step: "first_error").count).to eq(1)
      expect(organization.first_steps.find_by!(step: "first_error").reached_at).to eq(first_day)
    end
  end

  describe "alert rule" do
    def save_rule(actor)
      Alerting::Rules::Save.call(rule: organization.alerting_rules.new, organization:, actor:,
                                 attributes: { name: "Nuovi errori", event_type: "error_new", throttle_seconds: 300 })
    end

    it "is ticked when a person creates a rule, with today's date" do
      freeze_time do
        expect(save_rule(owner)).to be_ok

        expect(organization.first_steps.find_by!(step: "alert_rule").reached_at).to eq(Time.current)
      end
    end

    it "is not ticked by the default rules every organization gets at birth" do
      Alerting::Rules::InstallDefaults.call(organization:, created_by: owner)

      expect(organization.alerting_rules).to exist
      expect(steps).not_to include("alert_rule")
    end

    it "is not ticked by a service account" do
      save_rule(create(:account, :service))

      expect(steps).not_to include("alert_rule")
    end

    it "is not ticked by editing an existing rule" do
      rule = create(:alerting_rule, organization:)

      Alerting::Rules::Save.call(rule:, organization:, actor: owner, attributes: { name: "Renamed" })

      expect(steps).not_to include("alert_rule")
    end
  end

  it "invitation is ticked when the invitation leaves" do
    result = Connections::InviteMember.call(organization:, email: "new@example.com", role: "member", invited_by: owner)

    expect(result).to be_ok
    expect(steps).to eq([ "invitation" ])
  end

  describe "telegram" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      stub_request(:post, %r{api.telegram.org/.*/sendMessage}).to_return(status: 200)
    end

    it "a person linking their Telegram ticks it for every organization they belong to" do
      other = create(:organization)
      create(:membership, account: owner, organization: other, role: :member)
      code = Accounts::TelegramLinkCode.issue(account: owner)

      expect(Telegram::LinkAccount.call(token: code, chat_id: 4242)).to be_ok

      expect(Organizations::FirstStep.where(step: "telegram").pluck(:organization_id))
        .to contain_exactly(organization.id, other.id)
    end

    it "the owner linking the organization's group ticks it" do
      code = Accounts::TelegramLinkCode.issue(account: owner, organization: organization)

      expect(Telegram::LinkGroup.call(token: code, chat_id: -100, title: "Avvisi", forum: true)).to be_ok

      expect(steps).to eq([ "telegram" ])
    end
  end

  describe "closed ticket" do
    let(:done) { create(:ticket_status, :done, organization:) }
    let(:open) { create(:ticket_status, organization:) }

    it "is ticked when a ticket enters a closed status and stays ticked when it is reopened" do
      ticket = create(:ticket, organization:, project:, status: open)
      expect(steps).to be_empty

      ticket.update!(status: done)
      closed_at = ticket.closed_at
      ticket.update!(status: open)

      expect(ticket.reload.closed_at).to be_nil
      expect(organization.first_steps.find_by!(step: "ticket_closed").reached_at).to be_within(1.second).of(closed_at)
    end
  end
end
