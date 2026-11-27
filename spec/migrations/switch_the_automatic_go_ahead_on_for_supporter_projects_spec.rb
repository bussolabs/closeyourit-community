# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127090100_switch_the_automatic_go_ahead_on_for_supporter_projects")

# CYRA-1219 — the switch goes on where the supporter is on, LegalBloom excepted; the tickets the old supporter
# held on a contrary advice wait for a person, and `down` puts back exactly what `up` changed.
RSpec.describe SwitchTheAutomaticGoAheadOnForSupporterProjects do
  let(:organization) { create(:organization) }
  let(:migration) { described_class.new }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  def hold_on_contrary_advice(ticket, reason: "It drops a production table.")
    ticket.update_columns(agent_eligibility: 2, agent_eligibility_source: 0, agent_eligibility_advice: 2,
                          agent_eligibility_reason: reason, agent_eligibility_advice_reason: reason,
                          agent_eligibility_decided_at: Time.zone.parse("2026-11-20 10:00"))
  end

  describe "the projects" do
    let!(:on) { create(:project, organization:, name: "Shop", supporter_enabled: true) }
    let!(:off) { create(:project, organization:, name: "Blog", supporter_enabled: false) }
    let!(:in_the_group) do
      create(:project, organization:, name: "Portal", supporter_enabled: true,
                       group: create(:group, organization:, name: "LegalBloom"))
    end
    let!(:by_name) { create(:project, organization:, name: "Legal Bloom Rails", supporter_enabled: true) }

    # AC-15
    it "switches the automatic go-ahead on where the supporter is on, except LegalBloom" do
      migrate(:up)

      expect([ on, off, in_the_group, by_name ].map { |project| project.reload.auto_go_ahead_enabled })
        .to eq([ true, false, false, false ])
    end

    it "switches every project back off when undone" do
      migrate(:up)
      migrate(:down)

      expect(on.reload.auto_go_ahead_enabled).to be(false)
    end

    it "stops in production when it cannot find LegalBloom" do
      in_the_group.group.update!(name: "Other")
      by_name.update!(name: "Other")
      allow(Rails.env).to receive(:production?).and_return(true)

      expect { migrate(:up) }.to raise_error(described_class::StoppedWithoutLegalBloom)
      expect(on.reload.auto_go_ahead_enabled).to be(false)
    end

    # CYRA-1365 — the staging server also runs with the production environment and has no LegalBloom
    # project: stopping there kept the application from starting, and no release reached production.
    it "goes on where the server is the staging one, which has no LegalBloom to protect" do
      in_the_group.group.update!(name: "Other")
      by_name.update!(name: "Other")
      allow(Rails.env).to receive(:production?).and_return(true)
      stub_const("ENV", ENV.to_h.merge("APP_HOSTS" => "closeyourit.staging.example.test"))

      expect { migrate(:up) }.not_to raise_error
      expect(on.reload.auto_go_ahead_enabled).to be(true)
    end
  end

  describe "the tickets" do
    let(:project) { create(:project, organization:, name: "Shop") }
    let(:ticket) { create(:ticket, organization:, project:) }

    # AC-17
    it "puts a ticket held on a contrary advice back to assess, with a history entry, and back when undone" do
      hold_on_contrary_advice(ticket)

      migrate(:up)

      expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_reason: nil)
      event = ticket.events.find_by!(action: "agent_eligibility_overridden")
      expect(event.data).to include("go_ahead" => "rollout_reopened", "held_reason" => "It drops a production table.")
      expect(Ticketing::ActivityPresenter.new(event).icon).to eq("rotate-ccw")
      expect(I18n.with_locale(:it) { Ticketing::ActivityPresenter.new(event).sentence }).to include("da valutare")

      migrate(:down)

      expect(ticket.reload).to have_attributes(agent_eligibility: "blocked", agent_eligibility_reason: "It drops a production table.",
                                               agent_eligibility_decided_at: Time.zone.parse("2026-11-20 10:00"))
      expect(ticket.events.where(action: "agent_eligibility_overridden")).to be_empty
    end

    # AC-18
    it "leaves a ticket held because its attempts ran out" do
      hold_on_contrary_advice(ticket)
      create(:agent_workflow, ticket:, organization:, cancelled_at: 1.hour.ago,
                              cancellation_reason: "#{Agents::Workflows::ExhaustedBudget::REASON_MARK} autopilot ran out of attempts twice")

      migrate(:up)

      expect(ticket.reload.agent_eligibility).to eq("blocked")
    end

    it "leaves a hold whose reason is not the contrary advice" do
      hold_on_contrary_advice(ticket)
      ticket.update_columns(agent_eligibility_reason: "The machines could not finish this work, twice.")

      migrate(:up)

      expect(ticket.reload.agent_eligibility).to eq("blocked")
    end

    # AC-9
    it "never touches a person's decision, going up or down" do
      hold_on_contrary_advice(ticket)
      ticket.update_columns(agent_eligibility_source: 1)

      migrate(:up)
      migrate(:down)

      expect(ticket.reload).to have_attributes(agent_eligibility: "blocked", agent_eligibility_source: "human")
    end

    it "keeps, when undone, what a person decided after the update" do
      hold_on_contrary_advice(ticket)
      migrate(:up)
      Ticketing::SetAgentEligibility.call(ticket: ticket.reload, source: :human, eligibility: "allowed", actor: ticket.reporter)

      migrate(:down)

      expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "human")
    end

    it "can run twice" do
      hold_on_contrary_advice(ticket)

      2.times { migrate(:up) }

      expect(ticket.events.where(action: "agent_eligibility_overridden").count).to eq(1)
    end
  end
end
