# frozen_string_literal: true

require "rails_helper"

# CYRA-595 — il rilascio in produzione è l'unico passo irreversibile della catena, ed è anche l'unico
# che non aveva niente a metterlo in fila. Due tag dello stesso repository girano in parallelo nella
# CI e finiscono in ordine qualunque: la produzione può restare su una versione più vecchia di quella
# appena rilasciata. A distanziarli era una persona che premeva «via libera» un ticket per volta,
# senza sapere di essere l'unico freno.
RSpec.describe Agents::Workflows::ProductionLock do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }

  def lavorazione(**attributi)
    ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
    ticket.agent_workflow.tap { |w| w.update!(**attributi) if attributi.any? }
  end

  describe "chi trattiene la fila" do
    it "una produzione avviata e non conclusa la trattiene" do
      lavorazione(closer_production_started_at: 1.minute.ago)

      expect(described_class).to be_locked(project:)
    end

    it "una produzione conclusa no" do
      lavorazione(closer_production_started_at: 1.hour.ago, completed_at: Time.current)

      expect(described_class).not_to be_locked(project:)
    end

    it "una lavorazione annullata no" do
      lavorazione(closer_production_started_at: 1.hour.ago, cancelled_at: Time.current)

      expect(described_class).not_to be_locked(project:)
    end

    # Il ramo che sembra un di più e non lo è: quando un rilascio va male, ReportFailure e MarkStale
    # RIAPRONO la fase — azzerano l'avvio — e solo dopo scrivono il blocco. Senza questo, un rilascio
    # fallito e in attesa di una persona smetterebbe di trattenere la fila, e il successivo partirebbe
    # proprio mentre quello prima è rotto.
    it "una produzione bloccata la trattiene anche se l'avvio è stato azzerato" do
      lavorazione(closer_production_started_at: nil, blocked_at: Time.current,
                  blocked_phase: "closer_production", blocked_kind: "attempt_limit")

      expect(described_class).to be_locked(project:)
    end

    it "un blocco su un'altra fase non la trattiene" do
      lavorazione(closer_production_started_at: nil, blocked_at: Time.current,
                  blocked_phase: "autopilot", blocked_kind: "attempt_limit")

      expect(described_class).not_to be_locked(project:)
    end

    it "una produzione su un altro repository non trattiene questo" do
      altro = create(:project, organization:)
      create(:github_repository, project: altro)
      ticket = create(:ticket, organization:, project: altro, with_agent_workflow: true)
      ticket.agent_workflow.update!(closer_production_started_at: 1.minute.ago)

      expect(described_class).not_to be_locked(project:)
    end

    it "una lavorazione non trattiene se stessa" do
      mia = lavorazione(closer_production_started_at: 1.minute.ago)

      expect(described_class).not_to be_locked(project:, except: mia)
    end

    it "dice QUALE lavorazione tiene la fila, la più vecchia" do
      vecchia = lavorazione(closer_production_started_at: 2.hours.ago)
      lavorazione(closer_production_started_at: 1.minute.ago)

      expect(described_class.holder(project:)).to eq(vecchia)
    end
  end

  # Due copie del predicato che divergono sarebbero due code diverse: quella rimasta indietro
  # proporrebbe lavoro che l'altra rifiuta, e il ticket girerebbe a vuoto senza che nessuno capisca
  # perché. La parità va verificata, non dichiarata.
  describe "il gemello Ruby dice la stessa cosa dell'SQL" do
    [
      { closer_production_started_at: 1.minute.ago },
      { closer_production_started_at: 1.hour.ago, completed_at: Time.current },
      { closer_production_started_at: 1.hour.ago, cancelled_at: Time.current },
      { blocked_at: Time.current, blocked_phase: "closer_production", blocked_kind: "attempt_limit" },
      { blocked_at: Time.current, blocked_phase: "autopilot", blocked_kind: "attempt_limit" },
      {}
    ].each do |attributi|
      it "combaciano su #{attributi.keys.join(', ').presence || 'una lavorazione appena nata'}" do
        workflow = lavorazione(**attributi)

        da_sql = described_class.holders(project:).exists?(id: workflow.id)

        expect(described_class.open?(workflow)).to eq(da_sql)
      end
    end
  end
end
