# frozen_string_literal: true

require "rails_helper"

# Refresh delle board che ospitano i DEPENDENTS di uno o più ticket (CYRA-82). Accetta un lotto perché
# il percorso che conta è Home::Approvals::BulkApprove: una query per card sarebbe un N+1 vero.
RSpec.describe Ticketing::DependentsBoardRefresh do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:other_project) { create(:project, organization: org) }
  let(:open_status) { create(:ticket_status, organization: org) }
  let(:blocker) { create(:ticket, organization: org, project: project, status: open_status) }

  def dependent_in(target_project, blocker:)
    ticket = create(:ticket, organization: org, project: target_project, status: open_status)
    create(:ticket_dependency, ticket: ticket, blocker: blocker)
    ticket
  end

  it "non rinfresca nulla senza ticket" do
    expect(Realtime::ThrottledRefresh).not_to receive(:call)

    result = described_class.call(tickets: [])

    expect(result).to be_ok
    expect(result.value).to eq(0)
  end

  it "non rinfresca nulla quando nessuno dipende dai ticket" do
    expect(Realtime::ThrottledRefresh).not_to receive(:call)

    expect(described_class.call(tickets: blocker).value).to eq(0)
  end

  it "rinfresca la board del progetto che ospita il dependent" do
    dependent_in(other_project, blocker: blocker)

    expect(Realtime::ThrottledRefresh).to receive(:call)
      .with(Realtime::Streams.project_board(other_project)).once

    expect(described_class.call(tickets: blocker).value).to eq(1)
  end

  it "salta il progetto dei ticket passati: quella board l'ha già rinfrescata chi ha cambiato stato" do
    dependent_in(project, blocker: blocker)

    expect(Realtime::ThrottledRefresh).not_to receive(:call)

    expect(described_class.call(tickets: blocker).value).to eq(0)
  end

  it "rinfresca una volta sola il progetto che ospita più dependents" do
    2.times { dependent_in(other_project, blocker: blocker) }

    expect(Realtime::ThrottledRefresh).to receive(:call)
      .with(Realtime::Streams.project_board(other_project)).once

    expect(described_class.call(tickets: blocker).value).to eq(1)
  end

  # Il motivo per cui il service accetta un lotto: nel bulk la query dev'essere UNA, altrimenti è
  # l'N+1 che il guard Prosopite fa fallire già alla seconda card accettata.
  it "risolve un lotto di ticket con una sola query" do
    blockers = Array.new(3) { create(:ticket, organization: org, project: project, status: open_status) }
    blockers.each { |b| dependent_in(other_project, blocker: b) }
    allow(Realtime::ThrottledRefresh).to receive(:call)

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].include?("connections_ticket_dependencies")
    end
    described_class.call(tickets: blockers)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(queries.size).to eq(1)
  end
end
