# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ReviewPage, knowledge_review: true do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:good_body) { "Formato: troubleshooting\n\n## Sintomo\n`boom`\n## Causa\nx\n## Correzione\ny\n## Verifica\nz" }
  let(:accept) { JSON.parse(Rails.root.join("spec/fixtures/knowledge/review/verdict_accept.json").read) }
  let(:reject) { JSON.parse(Rails.root.join("spec/fixtures/knowledge/review/verdict_reject.json").read) }
  let(:client) { instance_double(Ai::Llm::Client, usage: Ai::Llm::Client::Usage.new(tokens_input: 1, tokens_output: 1, model: "qwen", request_id: nil)) }

  def review(**options)
    described_class.call(**{ title: "Rails — la cache non tiene niente in prova", body: good_body, tech_spec: nil, kind: "note",
                             tags: %w[rails test], scope: Knowledge::Page.where(organization_id: org.id), neighbours: false, client: client }.merge(options))
  end

  it "spento dal god: nessun verdetto, nessuna chiamata, una riga nel registro" do
    Settings::Global.instance.update!(ai_knowledge_review_enabled: false)
    allow(Rails.logger).to receive(:warn)

    result = review
    expect(result).to be_ok
    expect(result.value).to be_nil
    expect(client).not_to have_received(:generate_content) if client.respond_to?(:generate_content)
    expect(Rails.logger).to have_received(:warn).with(/spento dal god/)
  end

  it "il pre-check che boccia non chiama il modello" do
    allow(client).to receive(:generate_content)

    verdict = review(title: "senza area").value
    expect(verdict).to be_rejected
    expect(verdict.violations.map(&:code)).to eq([ "K02" ])
    expect(verdict.model).to be_nil
    expect(client).not_to have_received(:generate_content)
  end

  it "legacy: il pre-check lascia passare forma mancante e il prompt chiede di dedurre il formato" do
    prompts = []
    allow(client).to receive(:generate_content) { |contents:, **| prompts << contents.first[:parts].first[:text]; accept }

    verdict = review(legacy: true, title: "senza area", body: "## Sintomo\n`x`", tags: []).value
    expect(verdict).to be_accepted
    expect(verdict.violations.map { |v| [ v.code, v.blocking ] }).to eq([ [ "K02", false ] ])
    expect(prompts.last).to include("modalità legacy")
  end

  it "precheck_only: le regole meccaniche bocciano, altrimenti nessun verdetto e nessuna chiamata" do
    allow(client).to receive(:generate_content)

    expect(review(precheck_only: true, tags: []).value.violations.map(&:code)).to eq([ "K11" ])
    expect(review(precheck_only: true).value).to be_nil
    expect(client).not_to have_received(:generate_content)
  end

  it "passa al modello le regole, la pagina e lo schema, e ritorna il verdetto" do
    allow(client).to receive(:generate_content) { |system:, contents:, response_schema:, **options|
      expect(system).to include("## Regole comuni")
      expect(contents.first[:parts].first[:text]).to include("Titolo: Rails — la cache").and include("--- Corpo ---")
      expect(response_schema).to eq(Knowledge::Review::SCHEMA)
      expect(options[:deadline_seconds]).to eq(Knowledge::Constants::REVIEW_DEADLINE_SECONDS)
      expect(options[:max_output_tokens]).to eq(Knowledge::Constants::REVIEW_MAX_OUTPUT_TOKENS)
      accept
    }

    verdict = review.value
    expect(verdict).to be_accepted
    expect(verdict.model).to eq("qwen")
  end

  it "un rifiuto del modello porta le violazioni, dopo gli avvisi del pre-check" do
    allow(client).to receive(:generate_content).and_return(reject)

    verdict = review(title: "Nuxt — deploy (parte 1/2)", body: "Formato: procedura\n1. a\n2. b\n3. c", kind: "guide").value
    expect(verdict).to be_rejected
    expect(verdict.violations.map(&:code)).to eq(%w[P05_missing T01 K04])
  end

  it "server AI giù → R503-KNOWLEDGE-001 con la causa, e la pagina non entra" do
    allow(client).to receive(:generate_content).and_raise(Ai::Llm::Client::Error.new("giù", code: "R503-LLM-001", status: :service_unavailable))

    result = review
    expect(result).to be_err
    expect(result.error.code).to eq("R503-KNOWLEDGE-001")
    expect(result.error.status).to eq(:service_unavailable)
    expect(result.error.details).to eq({ cause: "R503-LLM-001" })
  end

  it "ENV assenti → R503-KNOWLEDGE-001 con causa unconfigured, mai 500" do
    result = review(client: nil)
    expect(result.error.code).to eq("R503-KNOWLEDGE-001")
    expect(result.error.details).to eq({ cause: "unconfigured" })
  end

  it "verdetto illeggibile → R502-KNOWLEDGE-001" do
    allow(client).to receive(:generate_content).and_return({ "format" => "poesia", "verdict" => "accept" })

    expect(review.error.code).to eq("R502-KNOWLEDGE-001")
  end

  it "i titoli dello SCOPE risolvono i wikilink: né le scartate, né le pagine fuori scope" do
    create(:knowledge_page, organization: org, project: project, title: "Rails — una cosa")
    create(:knowledge_page, organization: org, project: project, title: "Rails — scartata", status: :rejected)
    other = create(:project, organization: org)
    create(:knowledge_page, organization: org, project: other, title: "Rails — riservata")
    allow(client).to receive(:generate_content).and_return(accept)
    scope = Knowledge::Page.where(organization_id: org.id).for_projects([ project.id ])

    expect(review(body: "#{good_body}\nVedi [[Rails — una cosa]]", scope:).value).to be_accepted
    expect(review(body: "#{good_body}\nVedi [[Rails — scartata]]", scope:).value.violations.map(&:code)).to eq([ "K14" ])
    found = review(body: "#{good_body}\nVedi [[Rails — riservata]]", scope:).value
    expect(found.violations.map(&:code)).to eq([ "K14" ])
  end

  it "mette nel prompt i titoli delle pagine vicine per embedding, e va avanti se l'embedding è giù" do
    prompts = []
    allow(client).to receive(:generate_content) { |contents:, **| prompts << contents.first[:parts].first[:text]; accept }
    allow(Embeddings::QueryVector).to receive(:call).and_return(Result.err(AppError.new("giù", code: "R502-AI-001")))

    expect(review(neighbours: true).value).to be_accepted
    expect(prompts.last).not_to include("Pagine vicine")
  end
end

# CYAU-200 — la stessa pagina rifiutata al primo invio e accettata identica al secondo: chi pubblica
# non sapeva se correggere o riprovare. Il giudizio si ricorda per la domanda esatta, così l'esito
# non dipende da quale giro capita.
RSpec.describe Knowledge::ReviewPage, "memoria del verdetto", knowledge_review: true do
  let(:org) { create(:organization) }
  let(:good_body) { "Formato: troubleshooting\n\n## Sintomo\n`boom`\n## Causa\nx\n## Correzione\ny\n## Verifica\nz" }
  let(:accept) { JSON.parse(Rails.root.join("spec/fixtures/knowledge/review/verdict_accept.json").read) }
  let(:reject) { JSON.parse(Rails.root.join("spec/fixtures/knowledge/review/verdict_reject.json").read) }
  let(:client) { instance_double(Ai::Llm::Client, usage: Ai::Llm::Client::Usage.new(tokens_input: 1, tokens_output: 1, model: "qwen", request_id: nil)) }
  # In test l'app usa :null_store (ogni read → nil): senza uno store vero non c'è niente da
  # ricordare. Stesso pattern di spec/support/valhalla_service_health_cache.rb.
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def review(**options)
    described_class.call(**{ title: "Rails — la cache non tiene niente in prova", body: good_body, tech_spec: nil, kind: "note",
                             tags: %w[rails test], scope: Knowledge::Page.where(organization_id: org.id), neighbours: false, client: client }.merge(options))
  end

  it "la stessa pagina due volte: un solo giro dal modello e lo stesso esito" do
    risposte = [ reject, accept ]
    allow(client).to receive(:generate_content) { risposte.shift }

    primo = review.value
    secondo = review.value

    expect(client).to have_received(:generate_content).once
    expect(primo).to be_rejected
    expect(secondo).to be_rejected
    expect(secondo.violations.map(&:code)).to eq(primo.violations.map(&:code))
    expect(secondo.model).to eq("qwen")
  end

  it "una pagina cambiata è una domanda nuova" do
    allow(client).to receive(:generate_content).and_return(accept)

    review
    review(body: "#{good_body}\nuna riga in più")

    expect(client).to have_received(:generate_content).twice
  end

  it "due salvataggi gemelli in volo insieme: vale la prima risposta arrivata in fondo, per tutti e due" do
    gemello = nil
    chiamate = 0
    allow(client).to receive(:generate_content) do
      chiamate += 1
      mia = chiamate
      # Il gemello parte mentre il primo aspetta il modello, e arriva in fondo prima di lui.
      gemello = review.value if mia == 1
      mia == 1 ? reject : accept
    end

    primo = review.value

    expect(client).to have_received(:generate_content).twice
    expect(gemello).to be_accepted
    expect(primo).to be_accepted
    expect(primo.violations.map(&:code)).to eq(gemello.violations.map(&:code))
  end

  it "un verdetto illeggibile non si ricorda: il giro dopo si richiede" do
    risposte = [ { "format" => "poesia", "verdict" => "accept" }, accept ]
    allow(client).to receive(:generate_content) { risposte.shift }

    expect(review.error.code).to eq("R502-KNOWLEDGE-001")
    expect(review.value).to be_accepted
    expect(client).to have_received(:generate_content).twice
  end
end
