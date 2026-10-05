# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::PlanDocument do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }

  def plan(**attributes)
    Agents::Plan.create!(
      workflow:, attempt:, ticket_snapshot_digest: "snapshot", technical_analysis: "Analisi legacy",
      scenarios: [], definition_of_done: [], notes: [], **attributes
    )
  end

  it "normalizza un piano v2 per pagina e Markdown" do
    record = plan(
      contract_version: 2,
      content: {
        "summary" => "Il risultato è leggibile.",
        "work_items" => [
          { "id" => "WI-1", "title" => "Rendere il piano", "description" => "Separare le parti.",
            "files" => [ { "path" => "app/models/agents/plan.rb", "line" => 12,
                           "reason" => "Conserva il dato." } ], "dependencies" => [] }
        ],
        "rationale" => [ "Una sorgente evita divergenze." ],
        "risks" => [ { "id" => "R-1", "title" => "Storico", "impact" => "Manca la struttura.",
                       "mitigation" => "Usare il fallback v1." } ],
        "open_points" => [],
        "sources" => [ { "path" => "app/models/agents/plan.rb", "reason" => "Fonte del piano." } ]
      },
      scenarios: [ { "id" => "SC-1", "title" => "Scheda leggibile", "given" => "un locale con tre foto",
                     "when" => "apro la sua scheda", "then" => "vedo le foto e posso cambiarle",
                     "expected" => "senza passare dal sito" } ],
      definition_of_done: [ { "id" => "DOD-1", "text" => "La scheda usa una frase leggibile" } ]
    )

    document = described_class.new(record)

    expect(document.summary).to eq("Il risultato è leggibile.")
    expect(document.scenarios.sole.fetch("id")).to eq("SC-1")
    expect(document.definition_of_done.sole.fetch("text")).to eq("La scheda usa una frase leggibile")
    expect(document.technical_analysis).to include("Rendere il piano", "app/models/agents/plan.rb:12", "Storico")
  end

  it "mantiene leggibili i piani v1 senza inventare struttura" do
    record = plan(
      scenarios: [ { "given" => "un ticket", "when" => "lo apro", "then" => "vedo il piano",
                     "expected" => "senza errori" } ],
      definition_of_done: [ "La pagina resta leggibile" ]
    )

    document = described_class.new(record)

    expect(document.legacy?).to be(true)
    expect(document.summary).to eq("Analisi legacy")
    expect(document.scenarios.sole).to include("given" => "un ticket")
    expect(document.definition_of_done.sole).to eq("id" => nil, "text" => "La pagina resta leggibile")
  end

  # CYRA-702 — il brief per chi decide: c'è solo se l'agente l'ha scritto, mai inventato.
  it "espone il brief decisionale quando c'è e tace quando manca" do
    with_brief = plan(contract_version: 2, content: { "summary" => "Sintesi." },
                      decision_brief: "L'app potrà creare gli eventi.")
    without_brief = plan(contract_version: 2, content: { "summary" => "Sintesi." })

    expect(described_class.new(with_brief).decision_brief).to eq("L'app potrà creare gli eventi.")
    expect(described_class.new(without_brief).decision_brief).to be_nil
    expect(described_class.new(plan).decision_brief).to be_nil
  end

  it "corregge la prosa senza modificare path e identificatori" do
    normalized = described_class.normalize_content(
      summary: "Il lavoro e' gia pronto",
      work_items: [ { id: "WI-1", files: [ { path: "app/gia/perche.rb",
                                             reason: "Perche' serve" } ] } ]
    )

    expect(normalized["summary"]).to eq("Il lavoro è già pronto")
    expect(normalized.dig("work_items", 0, "files", 0, "path")).to eq("app/gia/perche.rb")
    expect(normalized.dig("work_items", 0, "files", 0, "reason")).to eq("Perché serve")
  end

  # CYRA-885 — the approver's card comes from the agent result; the server may only raise its risk.
  describe "#decision_card" do
    let(:card) do
      { "headline" => "La guida spiegherà il resoconto dei costi.",
        "points" => [ { "label" => "Cosa cambia", "text" => "Solo la guida." } ],
        "risk_level" => "none", "risk" => nil }
    end

    def v2_plan(files: [ "README.md" ], risks: [])
      attempt.update!(result: { "decision_card" => card })
      plan(contract_version: 2, content: {
             "summary" => "Sintesi.", "rationale" => [], "open_points" => [], "sources" => [], "risks" => risks,
             "work_items" => [ { "id" => "WI-1", "title" => "Guida", "description" => "Scrivere.",
                                 "files" => files.map { |path| { "path" => path, "reason" => "Qui." } },
                                 "dependencies" => [] } ]
           })
    end

    it "returns the card the agent wrote" do
      document = described_class.new(v2_plan)

      expect(document.decision_card).to include("headline" => card["headline"], "risk_level" => "none")
      expect(document.decision_card["points"]).to eq(card["points"])
    end

    it "is nil when the agent wrote no card" do
      expect(described_class.new(plan(contract_version: 2, content: { "summary" => "Sintesi." })).decision_card).to be_nil
    end

    it "raises the risk to low when the plan lists risks" do
      risks = [ { "id" => "R-1", "title" => "Nome", "impact" => "Cambia.", "mitigation" => "Nessuna." } ]

      expect(described_class.new(v2_plan(risks:)).decision_card["risk_level"]).to eq("low")
    end

    it "raises the risk to high when a work item touches a migration" do
      document = described_class.new(v2_plan(files: [ "db/migrate/20260930000000_add_column.rb" ]))

      expect(document.decision_card["risk_level"]).to eq("high")
    end

    it "never lowers the level the agent declared" do
      card["risk_level"] = "high"

      expect(described_class.new(v2_plan).decision_card["risk_level"]).to eq("high")
    end
  end
end
