# frozen_string_literal: true

require "rails_helper"
require "timeout"

# Scenario 5 del ticket: due transazioni tentano insieme A→B e B→A. Il lock deterministico sui ticket
# coinvolti (id ordinati) serializza il controllo del ciclo → al massimo una riesce, mai un ciclo
# persistito. Serve PostgreSQL reale e connessioni separate: niente transactional tests.
RSpec.describe Connections::TicketDependency, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) do
    create(:account).tap { |account| create(:membership, account:, organization:) }
  end
  let!(:ticket_a) { create(:ticket, organization:, project:, reporter: actor, reviewer: actor) }
  let!(:ticket_b) { create(:ticket, organization:, project:, reporter: actor, reviewer: actor) }

  after do
    described_class.delete_all
    ticket_a.destroy! if ticket_a.persisted?
    ticket_b.destroy! if ticket_b.persisted?
    organization.reload.destroy! if organization.persisted?
    actor.reload.destroy! if actor.persisted?
  end

  it "serializza le create opposte concorrenti: una sola riesce, mai un ciclo persistito" do
    gate = Queue.new
    release = Queue.new
    forward = nil
    backward = nil

    # Rendezvous: entrambi i thread superano la validazione applicativa (nessun ciclo esiste ancora) e
    # si fermano ALL'INGRESSO del guard, PRIMA di prendere il lock. Poi vengono rilasciati insieme e
    # corrono verso il lock: è il DB, non il timing dei thread, a serializzarli.
    allow_any_instance_of(described_class).to receive(:reject_cycle_under_lock).and_wrap_original do |original, *args|
      gate << true
      release.pop
      original.call(*args)
    end

    forward = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.create(ticket_id: ticket_a.id, blocker_id: ticket_b.id, created_by_id: actor.id)
      end
    end
    backward = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.create(ticket_id: ticket_b.id, blocker_id: ticket_a.id, created_by_id: actor.id)
      end
    end

    Timeout.timeout(5) { 2.times { gate.pop } }
    2.times { release << true }

    results = Timeout.timeout(10) { [ forward.value, backward.value ] }
    persisted = results.select(&:persisted?)
    rejected = results.reject(&:persisted?)

    expect(persisted.size).to eq(1)
    expect(rejected.size).to eq(1)
    expect(rejected.first.errors.added?(:base, :creates_cycle)).to be true
    # Invariante centrale: mai A→B e B→A insieme.
    expect(described_class.where(ticket_id: [ ticket_a.id, ticket_b.id ]).count).to eq(1)
  ensure
    release << true if release
    [ forward, backward ].each do |thread|
      next unless thread

      thread.kill if thread.alive?
      thread.join
    end
  end
end
