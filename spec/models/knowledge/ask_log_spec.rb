# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::AskLog, type: :model do
  it "la factory è valida" do
    expect(build(:knowledge_ask_log)).to be_valid
  end

  it "richiede la domanda" do
    expect(build(:knowledge_ask_log, question: nil)).to be_invalid
  end

  describe ".record!" do
    let(:org) { create(:organization) }
    let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) } }
    let(:project) { create(:project, organization: org) }

    it "persiste domanda, risposta, scope e citazioni" do
      log = described_class.record!(
        account: account, organization: org, question: "Che DB usiamo?",
        answer: "PostgreSQL.", insufficient: false, full_access: false,
        project_ids: [ project.id ], group_ids: [],
        citations: [ { "id" => "1", "title" => "Scelta DB", "url" => "/x" } ]
      )

      expect(log).to be_persisted
      expect(log.question).to eq("Che DB usiamo?")
      expect(log.answer).to eq("PostgreSQL.")
      expect(log.project_ids).to eq([ project.id ])
      expect(log.citations).to eq([ { "id" => "1", "title" => "Scelta DB", "url" => "/x" } ])
    end

    it "normalizza full_access/insufficient a booleano e le liste a array" do
      log = described_class.record!(
        account: account, organization: org, question: "?", answer: nil,
        insufficient: true, full_access: nil, project_ids: nil, group_ids: nil, citations: nil
      )

      expect(log.insufficient).to be(true)
      expect(log.full_access).to be(false)
      expect(log.project_ids).to eq([])
      expect(log.group_ids).to eq([])
      expect(log.citations).to eq([])
    end
  end

  describe ".visible_to (stessa visibilità delle pagine)" do
    let(:org) { create(:organization) }
    let(:member) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) } }
    let(:project_a) { create(:project, organization: org) }
    let(:project_b) { create(:project, organization: org) }
    let(:group) { create(:group, organization: org) }

    let!(:on_a)      { create(:knowledge_ask_log, organization: org, project_ids: [ project_a.id ]) }
    let!(:on_b)      { create(:knowledge_ask_log, organization: org, project_ids: [ project_b.id ]) }
    let!(:org_wide)  { create(:knowledge_ask_log, :org_wide, organization: org) }
    let!(:on_group)  { create(:knowledge_ask_log, organization: org, group_ids: [ group.id ]) }

    def visible_for(pids, gids, full: false)
      described_class.visible_to(account: member, organization: org, full_access: full,
                                 visible_project_ids: pids, visible_group_ids: gids)
    end

    it "chi ha accesso pieno vede tutto lo storico dell'org" do
      expect(visible_for([], [], full: true)).to contain_exactly(on_a, on_b, org_wide, on_group)
    end

    it "chi vede solo un progetto vede le sue domande, non quelle degli altri progetti né le org-wide" do
      visible = visible_for([ project_a.id ], [])

      expect(visible).to include(on_a)
      expect(visible).not_to include(on_b, org_wide)
    end

    it "chi vede un gruppo vede le domande poste su quel gruppo" do
      expect(visible_for([], [ group.id ])).to include(on_group)
    end

    it "chi non vede nessun progetto/gruppo (e non è full) non vede nulla" do
      expect(visible_for([], [])).to be_empty
    end

    it "hides answers that combine a visible and a hidden project" do
      combined = create(:knowledge_ask_log, organization: org, project_ids: [ project_a.id, project_b.id ])
      expect(visible_for([ project_a.id ], [])).not_to include(combined)
      expect(visible_for([ project_a.id, project_b.id ], [])).to include(combined)
    end

    it "requires both project and group access for a mixed answer" do
      combined = create(:knowledge_ask_log, organization: org, project_ids: [ project_a.id ], group_ids: [ group.id ])
      expect(visible_for([ project_a.id ], [])).not_to include(combined)
      expect(visible_for([], [ group.id ])).not_to include(combined)
      expect(visible_for([ project_a.id ], [ group.id ])).to include(combined)
    end

    it "non mescola lo storico di un'altra organizzazione" do
      other = create(:knowledge_ask_log, project_ids: [ create(:project).id ])

      expect(visible_for([ project_a.id ], [], full: true)).not_to include(other)
    end
  end

  it ".recent ordina dalla più recente" do
    old = create(:knowledge_ask_log, created_at: 2.days.ago)
    fresh = create(:knowledge_ask_log, created_at: 1.hour.ago)

    expect(described_class.recent.first(2)).to eq([ fresh, old ])
  end
end
