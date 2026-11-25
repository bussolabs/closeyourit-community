# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::BackfillGroupUsersJob, type: :job do
  let(:project) { create(:project) }

  def payload(event_id, user: { "id" => "user-1" })
    { "event_id" => event_id, "message" => "boom", "user" => user }
  end

  it "riempie l'elenco con le persone delle occorrenze conservate, una volta per persona" do
    group = create(:error_group, project:, users_count: 2)
    create_list(:error_event, 2, group:, project:, user_hash: "a" * 16)
    create(:error_event, group:, project:, user_hash: "b" * 16)
    create(:error_event, group:, project:, user_hash: nil)

    described_class.perform_now

    expect(group.group_users.pluck(:user_hash)).to contain_exactly("a" * 16, "b" * 16)
  end

  it "è idempotente e non tocca le persone già nell'elenco" do
    group = create(:error_group, project:, users_count: 1)
    create(:error_event, group:, project:, user_hash: "a" * 16)
    Errors::GroupUser.create!(group:, user_hash: "a" * 16)

    expect { 2.times { described_class.perform_now } }.not_to change(Errors::GroupUser, :count)
  end

  # Errore di prima della modifica: le occorrenze conservate di un utente, l'elenco vuoto. Dopo il
  # riempimento il ritorno dell'utente non conta né ora né dopo la potatura.
  it "chi torna dopo il riempimento non è contato di nuovo, né ora né dopo la potatura" do
    Settings::Global.instance.update!(errors_retention_days: 30)
    Errors::Ingest::Record.call(project:, payload: payload("1" * 32))
    Errors::GroupUser.delete_all

    described_class.perform_now
    Errors::Ingest::Record.call(project:, payload: payload("2" * 32))
    expect(project.error_groups.sole.users_count).to eq(1)

    travel(31.days) do
      Errors::PruneEventsJob.perform_now
      Errors::Ingest::Record.call(project:, payload: payload("3" * 32))
    end
    expect(project.error_groups.sole.users_count).to eq(1)
  end
end
