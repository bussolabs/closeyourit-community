# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::MatrixCoverage do
  let(:org) { create(:organization) }
  let(:group) { create(:group, organization: org) }
  let(:category) { create(:product_category, group: group, organization: org) }
  let(:web) { create(:platform, organization: org, label: "Web") }

  def feature
    create(:product_feature, category: category, organization: org)
  end

  def cell(feat, platform, status)
    create(:feature_platform, feature: feat, platform: platform, status: status)
  end

  # Conta le query SQL emesse dal blocco, escluse quelle di schema e le transazioni.
  def count_queries
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:name] == "SCHEMA"
      next if payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i)

      count += 1
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  describe ".for" do
    it "senza gruppi restituisce una mappa vuota" do
      expect(described_class.for(group_ids: [])).to eq({})
    end

    it "conta come attesa ogni cella tranne quelle «non applicabile»" do
      cell(feature, web, create(:feature_status, organization: org))               # planned
      cell(feature, web, create(:feature_status, :available, organization: org))   # available
      cell(feature, web, create(:feature_status, :not_applicable, organization: org))

      row = described_class.for(group_ids: [ group.id ]).fetch(group.id).first

      expect(row.expected).to eq(2)
    end

    it "conta come coperta solo una cella rilasciata (disponibile o in dismissione)" do
      cell(feature, web, create(:feature_status, organization: org))                 # planned → no
      cell(feature, web, create(:feature_status, :in_development, organization: org)) # in sviluppo → no
      cell(feature, web, create(:feature_status, :available, organization: org))      # sì
      cell(feature, web, create(:feature_status, :deprecated, organization: org))     # sì

      row = described_class.for(group_ids: [ group.id ]).fetch(group.id).first

      expect(row.covered).to eq(2)
      expect(row.expected).to eq(4)
    end

    it "non include una piattaforma dove c'è solo «non applicabile» (nessuna attesa)" do
      cell(feature, web, create(:feature_status, :not_applicable, organization: org))

      expect(described_class.for(group_ids: [ group.id ]).fetch(group.id)).to be_empty
    end

    it "tiene separati i conteggi di prodotti diversi" do
      other_group = create(:group, organization: org)
      other_category = create(:product_category, group: other_group, organization: org)
      status = create(:feature_status, :available, organization: org)

      cell(feature, web, status)
      cell(create(:product_feature, category: other_category, organization: org), web, status)

      result = described_class.for(group_ids: [ group.id, other_group.id ])

      expect(result.fetch(group.id).first.covered).to eq(1)
      expect(result.fetch(other_group.id).first.covered).to eq(1)
    end

    it "restituisce una lista vuota per un prodotto senza celle" do
      expect(described_class.for(group_ids: [ group.id ]).fetch(group.id)).to eq([])
    end

    it "considera completa la copertura quando tutte le attese sono coperte" do
      cell(feature, web, create(:feature_status, :available, organization: org))

      row = described_class.for(group_ids: [ group.id ]).fetch(group.id).first

      expect(row).to be_complete
    end

    it "resta a poche query fisse anche con molti prodotti (nessun N+1)" do
      status = create(:feature_status, :available, organization: org)
      groups = Array.new(3) do
        other = create(:group, organization: org)
        other_category = create(:product_category, group: other, organization: org)
        cell(create(:product_feature, category: other_category, organization: org), web, status)
        other
      end

      queries = count_queries { described_class.for(group_ids: groups.map(&:id)) }

      expect(queries).to be <= 3
    end
  end
end
