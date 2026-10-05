# frozen_string_literal: true

require "rails_helper"
require "timeout"

# Scenario 6 del ticket (CYRA-81): B viene riaperto in concorrenza mentre A sta passando a done. Il
# ricontrollo dei prerequisiti avviene DENTRO la transazione, sotto SELECT ... FOR UPDATE preso PRIMA
# della rivalutazione → non c'è finestra tra check e commit: A vede B non-done e fallisce. Serve
# PostgreSQL reale e connessioni separate: niente transactional tests.
RSpec.describe Ticketing::ChangeStatus, "anti-race sul gate dipendenze" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:open_status) { create(:ticket_status, organization:) }
  let(:done) { create(:ticket_status, :done, organization:) }
  let(:actor) do
    create(:account).tap { |account| create(:membership, account:, organization:) }
  end
  # A dipende da B, con B inizialmente DONE: senza il ricontrollo fresco A passerebbe a done.
  let!(:ticket_a) { create(:ticket, organization:, project:, status: open_status, reporter: actor, reviewer: actor) }
  let!(:blocker_b) { create(:ticket, organization:, project:, status: done, reporter: actor, reviewer: actor) }
  let!(:dependency) { create(:ticket_dependency, ticket: ticket_a, blocker: blocker_b, created_by: actor) }

  after do
    Connections::TicketDependency.delete_all
    ticket_a.destroy! if ticket_a.persisted?
    blocker_b.destroy! if blocker_b.persisted?
    organization.reload.destroy! if organization.persisted?
    actor.reload.destroy! if actor.persisted?
  end

  it "B riaperto (committato) prima che A prenda il lock: il ricontrollo lo vede non-done → R422-TICKET-014" do
    gate = Queue.new
    release = Queue.new
    changer = nil

    # Fermo il cambio stato di A all'INGRESSO del guard, PRIMA di prendere il lock: nel frattempo
    # un'altra connessione riapre B e committa. Al rilascio A prende il lock e RIVALUTA i prerequisiti.
    allow_any_instance_of(Ticketing::DependencyGuard)
      .to receive(:lock_dependency_graph).and_wrap_original do |original, *args|
        gate << true
        release.pop
        original.call(*args)
      end

    changer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Ticketing::ChangeStatus.call(channel: :web, organization:, ticket: ticket_a, status_id: done.id)
      end
    end

    Timeout.timeout(5) { gate.pop } # A è fermo prima del lock
    ActiveRecord::Base.connection_pool.with_connection do
      blocker_b.update!(status: open_status) # B riaperto e committato su un'altra connessione
    end
    release << true # rilascio A: ora prende il lock e ricontrolla

    result = Timeout.timeout(10) { changer.value }

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-014")
    expect(ticket_a.reload.status).to eq(open_status)
    expect(blocker_b.reload.status).to eq(open_status)
  ensure
    release << true if release
    if changer
      changer.kill if changer.alive?
      changer.join
    end
  end
end
