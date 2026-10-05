# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Knowledge::Pages::Publish, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }
  let(:publication_key) { "kb:concurrent:deploy" }
  let(:params) { { title: "Deploy", body: "Versione concorrente", kind: "guide" } }

  before do
    create(:membership, account: actor, organization:, role: :member)
    create(:project_membership, account: actor, project:)
  end

  after do
    organization.destroy! if organization.persisted?
    actor.destroy! if actor.persisted?
  end

  it "fa convergere due INSERT partite dopo lookup negativi sulla stessa riga" do
    waiting = 0
    mutex = Mutex.new
    barrier = ConditionVariable.new
    threads = []

    allow_any_instance_of(described_class).to receive(:create_or_update).and_wrap_original do |original, pages|
      mutex.synchronize do
        waiting += 1
        barrier.broadcast
        barrier.wait(mutex) while waiting < 2
      end
      original.call(pages)
    end

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.call(
            project: Projects::Project.find(project.id),
            actor: Accounts::Account.find(actor.id),
            publication_key:,
            params:
          )
        end
      end
    end
    results = Timeout.timeout(10) { threads.map(&:value) }

    expect(results).to all(be_ok)
    expect(results.map { |result| result.value.page.id }.uniq.size).to eq(1)
    expect(project.knowledge_pages.where(publication_key:).sole.versions.count).to eq(1)
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  it "recupera adopt-vs-create quando la create vince dopo il lock della legacy" do
    legacy = create(:knowledge_page, project:, created_by: actor, title: "Legacy", body: "Corpo legacy")
    adopter_locked = Queue.new
    creator_finished = Queue.new
    adopter = nil

    allow_any_instance_of(described_class).to receive(:adopt_legacy).and_wrap_original do |original, page|
      adopter_locked << true
      creator_finished.pop
      original.call(page)
    end

    adopter = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          project: Projects::Project.find(project.id),
          actor: Accounts::Account.find(actor.id),
          publication_key:,
          params: { title: "Legacy", body: "Writer adozione", kind: "guide" }
        )
      end
    end
    Timeout.timeout(5) { adopter_locked.pop }

    creator = described_class.call(
      project: Projects::Project.find(project.id),
      actor: Accounts::Account.find(actor.id),
      publication_key:,
      params: { title: "Nuova", body: "Writer creazione", kind: "note" }
    )
    creator_finished << true
    adopted = Timeout.timeout(10) { adopter.value }

    expect([ creator, adopted ]).to all(be_ok)
    bound = project.knowledge_pages.where(publication_key:).sole
    expect([ creator.value.page.id, adopted.value.page.id ]).to all(eq(bound.id))
    expect(bound).to have_attributes(title: "Legacy", body: "Writer adozione", kind: "guide")
    expect(bound.versions.order(:number).pluck(:title, :body)).to eq(
      [ [ "Nuova", "Writer creazione" ], [ "Legacy", "Writer adozione" ] ]
    )
    expect(legacy.reload.publication_key).to be_nil
  ensure
    creator_finished << true
    if adopter&.alive?
      adopter.kill
      adopter.join
    end
  end
end
