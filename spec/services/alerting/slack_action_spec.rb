# frozen_string_literal: true

require "rails_helper"

# CYRA-1156 — every click redoes link, membership and permission; refusals are private.
RSpec.describe Alerting::SlackAction, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization:, role: :owner) } }
  let(:member) { create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) } }
  let(:rule) { create(:alerting_rule, organization:, name: "Nuovi errori") }
  let(:group) { create(:error_group, project:) }
  let(:message) { create(:alerting_slack_message, organization:, project:, rule:, subject: group) }

  before do
    Types::InstallDefaults.call(organization:)
    allow(Coworkers::Slack).to receive(:post_ephemeral)
    allow(Alerting::SlackRefreshJob).to receive(:perform_later)
  end

  def link(account, user_id: "U1", org: organization)
    Coworkers::SlackLink.create!(slack_team_id: "T1", slack_user_id: user_id, account:, organization: org)
  end

  def click(action, user_id: "U1")
    described_class.call(team_id: "T1", user_id:, channel: message.slack_channel, ts: message.slack_ts, action:)
  end

  def expect_private(key, locale: I18n.default_locale)
    expect(Coworkers::Slack).to have_received(:post_ephemeral)
      .with(channel: message.slack_channel, user: "U1", text: I18n.t(key, locale:))
  end

  describe "Me ne occupo" do
    it "assigns the error to the linked person and shows it on the message" do
      link(owner)

      expect(click("alert_claim").value).to eq(:claimed)

      expect(group.reload.assignee).to eq(owner)
      expect(message.reload).to have_attributes(claimed_by_id: owner.id, version: 2)
      expect(Alerting::SlackRefreshJob).to have_received(:perform_later).with(message.id, 2)
    end

    it "acts once when the same person presses twice" do
      link(owner)

      2.times { click("alert_claim") }

      expect(message.reload.version).to eq(2)
      expect(Alerting::SlackRefreshJob).to have_received(:perform_later).once
    end

    it "refuses privately someone linked but no longer in the organization" do
      link(owner)
      Connections::Membership.where(account_id: owner.id, organization_id: organization.id).delete_all

      expect(click("alert_claim").value).to eq(:refused_not_member)

      expect(group.reload.assignee).to be_nil
      expect(message.reload.claimed_by_id).to be_nil
      expect_private("alerting.slack.refusals.not_member", locale: owner.effective_locale)
    end

    it "refuses someone who may not assign errors" do
      link(member)

      click("alert_claim")

      expect(group.reload.assignee).to be_nil
      expect_private("alerting.slack.refusals.forbidden", locale: member.effective_locale)
    end
  end

  describe "a person without a link" do
    it "gets the linking instructions privately and nothing changes" do
      expect(click("alert_mute").value).to eq(:refused_link_first)

      expect(rule.reload).not_to be_muted
      expect(message.reload.version).to eq(1)
      expect_private("member.coworkers.slack.link_first")
    end

    it "counts a link made in another organization as no link" do
      link(owner, org: create(:organization))

      click("alert_claim")

      expect(group.reload.assignee).to be_nil
      expect_private("member.coworkers.slack.link_first")
    end
  end

  describe "Silenzia 1 ora" do
    it "mutes the whole rule for one hour and records who did it" do
      link(owner)

      freeze_time do
        expect(click("alert_mute").value).to eq(:muted)

        expect(rule.reload.muted_until).to eq(1.hour.from_now)
        expect(message.reload).to have_attributes(muted_by_id: owner.id, muted_until: 1.hour.from_now)
      end
    end

    it "refuses privately a colleague without the permission to manage alerts" do
      link(member)

      expect(click("alert_mute").value).to eq(:refused_forbidden)

      expect(rule.reload).not_to be_muted
      expect(message.reload.muted_by_id).to be_nil
      expect_private("alerting.slack.refusals.forbidden", locale: member.effective_locale)
    end

    it "does not mute twice" do
      link(owner)
      click("alert_mute")

      expect { click("alert_mute") }.not_to(change { rule.reload.muted_until })
      expect(Alerting::SlackRefreshJob).to have_received(:perform_later).once
    end
  end

  describe "Apri ticket" do
    it "opens the ticket once, however many clicks" do
      link(owner)

      expect { 2.times { click("alert_ticket") } }.to change(Ticketing::Ticket, :count).by(1)

      expect(message.reload.ticket).to eq(group.reload.ticket)
      expect(message.ticket_opened_by).to eq(owner)
    end

    it "refuses someone who may not promote errors" do
      link(member)

      expect { click("alert_ticket") }.not_to change(Ticketing::Ticket, :count)
      expect_private("alerting.slack.refusals.forbidden", locale: member.effective_locale)
    end
  end

  describe "an alert that is not an error" do
    let(:incident) { create(:uptime_incident, monitor: create(:uptime_monitor, project:)) }

    before { message.update!(subject: incident, event_type: "uptime_down") }

    it "keeps who took it on the message" do
      link(owner)

      expect(click("alert_claim").value).to eq(:claimed)
      expect(message.reload.claimed_by).to eq(owner)
    end

    it "cannot become a ticket from Slack" do
      link(owner)

      expect(click("alert_ticket").value).to eq(:refused_no_ticket)
      expect_private("alerting.slack.refusals.no_ticket", locale: owner.effective_locale)
    end
  end

  it "says so when the rule of the alert is gone" do
    link(owner)
    message.update!(rule: nil)

    expect(click("alert_mute").value).to eq(:refused_rule_gone)
  end

  it "does nothing on an alert that already recovered" do
    link(owner)
    message.update!(status: :recovered, recovered_at: Time.current)

    click("alert_claim")

    expect(group.reload.assignee).to be_nil
    expect_private("alerting.slack.refusals.recovered", locale: owner.effective_locale)
  end

  it "ignores an unknown action or a message it never posted" do
    expect(click("alert_open").value).to eq(:ignored)
    expect(described_class.call(team_id: "T1", user_id: "U1", channel: "C9", ts: "1.1", action: "alert_claim").value).to eq(:ignored)
    expect(Coworkers::Slack).not_to have_received(:post_ephemeral)
  end
end
