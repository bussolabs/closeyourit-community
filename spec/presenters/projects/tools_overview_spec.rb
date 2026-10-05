# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::ToolsOverview do
  let(:project) { create(:project) }

  def row(tool_code) = described_class.new(project).rows.find { |r| r.tool_code == tool_code }
  def status_of(tool_code) = row(tool_code)&.status

  describe "una fonte è assunta dalle chiamate ricevute (nessuna dichiarazione manuale)" do
    it "compare tra le righe con l'ultima versione vista e il link alla cronologia (source_id)" do
      source = create(:project_source, project:, tool_code: "closeyourit-ruby", version: "0.4.0", last_seen_at: 1.hour.ago)

      expect(status_of("closeyourit-ruby")).to eq(:ok)
      expect(row("closeyourit-ruby").version).to eq("0.4.0")
      expect(row("closeyourit-ruby").source_id).to eq(source.id)
      expect(row("closeyourit-ruby").history?).to be(true)
    end

    it "senza alcuna fonte osservata la card è vuota" do
      expect(described_class.new(project).any?).to be(false)
    end
  end

  describe "stato temporale della fonte" do
    it "confine FRESH inferiore: a 24h esatte è ancora :ok" do
      freeze_time do
        create(:project_source, project:, tool_code: "closeyourit-ruby", last_seen_at: 24.hours.ago)
        expect(status_of("closeyourit-ruby")).to eq(:ok)
      end
    end

    it "confine FRESH superiore: a 24h+1s diventa :stale" do
      freeze_time do
        create(:project_source, project:, tool_code: "closeyourit-ruby", last_seen_at: (24.hours + 1.second).ago)
        expect(status_of("closeyourit-ruby")).to eq(:stale)
      end
    end

    it "confine STALE inferiore: a 7g esatti è ancora :stale" do
      freeze_time do
        create(:project_source, project:, tool_code: "closeyourit-ruby", last_seen_at: 7.days.ago)
        expect(status_of("closeyourit-ruby")).to eq(:stale)
      end
    end

    it "confine STALE superiore: a 7g+1s diventa :missing (dismessa)" do
      freeze_time do
        create(:project_source, project:, tool_code: "closeyourit-ruby", last_seen_at: (7.days + 1.second).ago)
        expect(status_of("closeyourit-ruby")).to eq(:missing)
      end
    end
  end

  describe "fonte placeholder da scrub SDK (dato storico già in DB)" do
    it "una Projects::Source col nome scrubbato (FILTERED/[FILTERED]) non compare tra le righe" do
      create(:project_source, project:, tool_code: "FILTERED", last_seen_at: 1.hour.ago)
      create(:project_source, project:, tool_code: "[FILTERED]", last_seen_at: 1.hour.ago)
      create(:project_source, project:, tool_code: "closeyourit-js", last_seen_at: 1.hour.ago)

      codes = described_class.new(project).rows.map(&:tool_code)
      expect(codes).to include("closeyourit-js")
      expect(codes).not_to include("FILTERED", "[FILTERED]")
    end
  end

  describe "agent server derivato dagli host linkati" do
    it "un host visto di recente → riga agent :ok con la versione dell'agent, senza cronologia (source_id nil)" do
      create(:environment_host, project:,
             host: create(:server_host, :up, organization: project.organization, agent_version: "0.2.0"))

      expect(status_of("closeyourit-agent")).to eq(:ok)
      expect(row("closeyourit-agent").version).to eq("0.2.0")
      expect(row("closeyourit-agent").source_id).to be_nil
      expect(row("closeyourit-agent").history?).to be(false)
    end

    it "una Projects::Source reale con lo stesso code batte l'agent derivato (fonte reale > derivato)" do
      source = create(:project_source, project:, tool_code: "closeyourit-agent", version: "9.9.9", last_seen_at: 1.hour.ago)
      create(:environment_host, project:,
             host: create(:server_host, :up, organization: project.organization, agent_version: "0.2.0"))

      expect(row("closeyourit-agent").version).to eq("9.9.9")
      expect(row("closeyourit-agent").source_id).to eq(source.id)
    end
  end

  describe "ordinamento" do
    it "le fonti con problemi (missing) precedono quelle ok" do
      create(:project_source, project:, tool_code: "closeyourit-ruby", last_seen_at: 30.days.ago) # missing
      create(:project_source, project:, tool_code: "closeyourit-js", last_seen_at: 1.hour.ago)     # ok

      codes = described_class.new(project).rows.map(&:tool_code)
      expect(codes.index("closeyourit-ruby")).to be < codes.index("closeyourit-js")
    end
  end
end
