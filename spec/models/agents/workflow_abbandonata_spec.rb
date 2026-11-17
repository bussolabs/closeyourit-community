# frozen_string_literal: true

require "rails_helper"

# CYRA-673 — «in corso» significava soltanto «avviata e mai conclusa», senza scadenza: una
# lavorazione che si ferma teneva bloccato lo stato del ticket per sempre, e l'unico modo di
# sbloccarlo era un clic umano su ogni singolo ticket.
#
# Misurato in produzione il 27/08/2026 su sei ticket fermi dal 23: nessun lease, zero tentativi
# vivi, tutti gia' `approved` o `review_failed`. Il lavoro era finito da giorni.
RSpec.describe Agents::Workflow, "#work_in_progress?" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:ticket) { create(:ticket, organization: organization, project: project, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }

  before { workflow.update!(triage_started_at: 2.days.ago) }

  context "quando un tentativo e' ancora in volo" do
    before { create(:agent_attempt, workflow: workflow, phase: "planning", status: :running) }

    it "il lavoro e' in corso" do
      expect(workflow.reload.work_in_progress?).to be(true)
    end
  end

  context "quando un titolare tiene ancora il ticket" do
    before do
      create(:agent_attempt, workflow: workflow, phase: "planning", status: :approved)
      create(:agent_lease, ticket: ticket, organization: organization,
                           host: create(:agent_host, organization: organization),
                           expires_at: 1.hour.from_now)
    end

    it "il lavoro e' in corso" do
      expect(workflow.reload.work_in_progress?).to be(true)
    end
  end

  context "quando nessuno tiene il ticket e tutti i tentativi sono conclusi da giorni" do
    before do
      create(:agent_attempt, workflow: workflow, phase: "planning", status: :approved)
      create(:agent_attempt, workflow: workflow, phase: "autopilot", status: :review_failed)
      # I sei ticket veri erano fermi da quattro giorni: qui si riproduce quella condizione,
      # perche' e' il TEMPO a distinguere una pausa fra due fasi da un abbandono.
      workflow.attempts.each { |a| a.update_columns(updated_at: 4.days.ago) }
    end

    it "il lavoro NON e' piu' in corso" do
      expect(workflow.reload.work_in_progress?).to be(false)
    end

    it "il ticket torna spostabile di stato dalla riga di comando" do
      risultato = Ticketing::ChangeStatus.call(
        organization: organization, ticket: ticket.reload,
        status_id: create(:ticket_status, organization: organization).id,
        channel: :cli, actor: create(:account)
      )
      expect(risultato).to be_ok
    end
  end

  context "quando il titolare e' scaduto" do
    before do
      create(:agent_attempt, workflow: workflow, phase: "planning", status: :approved)
      lease = create(:agent_lease, ticket: ticket, organization: organization,
                                   host: create(:agent_host, organization: organization))
      lease.update_columns(expires_at: 2.hours.ago)
      workflow.attempts.each { |a| a.update_columns(updated_at: 4.days.ago) }
    end

    it "un titolare scaduto non tiene piu' niente" do
      expect(workflow.reload.work_in_progress?).to be(false)
    end
  end

  # A machine that dies mid-phase leaves an attempt the server later closes as stale. Closing it touches the
  # attempt, and that touch used to count as a sign of life: the ticket stayed locked another 24 hours.
  context "when the server closed the latest attempt as stale (dead machine)" do
    before do
      workflow.update!(triage_started_at: 2.hours.ago)
      create(:agent_attempt, workflow: workflow, phase: "planning", status: :stale,
                             finished_at: Time.current, created_at: 90.minutes.ago)
    end

    it "is not in progress, so a person can move the ticket right away" do
      expect(workflow.reload.work_in_progress?).to be(false)
    end
  end

  context "when a stale attempt is older than the last finished one" do
    before do
      create(:agent_attempt, workflow: workflow, phase: "planning", status: :stale, created_at: 5.days.ago)
      create(:agent_attempt, workflow: workflow, phase: "autopilot", status: :approved, created_at: 4.days.ago)
      workflow.attempts.status_approved.each { it.update_columns(updated_at: 4.days.ago) }
      # Closed today by the recovery job: the closing must not read as recent work.
      workflow.attempts.status_stale.each { it.update_columns(updated_at: Time.current) }
    end

    it "does not count the stale closing as a sign of life" do
      expect(workflow.reload.work_in_progress?).to be(false)
    end
  end

  context "when a phase finished an hour ago and the next one has not started" do
    before do
      create(:agent_attempt, workflow: workflow, phase: "planning", status: :approved)
      workflow.attempts.each { it.update_columns(updated_at: 1.hour.ago) }
    end

    it "keeps the pause between phases protected" do
      expect(workflow.reload.work_in_progress?).to be(true)
    end
  end

  it "una lavorazione mai avviata non e' in corso, come prima" do
    workflow.update!(triage_started_at: nil)
    expect(workflow.reload.work_in_progress?).to be(false)
  end
end
