# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::RunJob, type: :job do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  # Chi ha fatto la domanda vede davvero quei progetti: dal CYRA-812 il perimetro congelato
  # all'invio viene ripassato dal perimetro di ADESSO, quindi un account senza link non legge nulla.
  def sees!(*projects)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
  end

  def owner! = create(:membership, account: account, organization: org, role: :owner)

  def triage_value
    Errors::TriageWithAi::Triage.new(
      category: "bug", severity_suggested: "high", root_cause: "nil deref",
      suggested_action: "resolve", confidence: "high", summary: "NPE nel widget"
    )
  end

  describe "ticket_analyze" do
    it "esegue il service e scrive il payload done con scenari + analisi tecnica" do
      project = create(:project, organization: org)
      request = create(:ai_request, account:, organization: org, kind: "ticket_analyze",
                                    args: { "project_id" => project.id, "text" => "non va" })
      analysis = Ticketing::AnalyzeBugReport::Analysis.new(
        complete: true,
        scenarios: [ { title: nil, step_given: "G", step_when: "W", step_then: "T", step_expected: "E" } ],
        technical_analysis: "stack qui", questions: []
      )
      allow(Ticketing::AnalyzeBugReport).to receive(:call)
        .with(project:, text: "non va").and_return(Result.ok(analysis))

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
      expect(request.payload).to include("complete" => true, "questions" => [], "technical_analysis" => "stack qui")
      expect(request.payload["scenarios"].first).to include("step_given" => "G")
    end
  end

  describe "ticket_compose" do
    it "esegue il service e scrive il payload done con titolo/kind/descrizione + scenari/DoD/analisi tecnica" do
      project = create(:project, organization: org)
      request = create(:ai_request, account:, organization: org, kind: "ticket_compose",
                                    args: { "project_id" => project.id, "text" => "il login va in timeout" })
      draft = Ticketing::ComposeTicket::Draft.new(
        title: "Timeout al login", kind: "bug", description: "Il login va in timeout dopo 30s.",
        technical_analysis: "gateway a 30s",
        scenarios: [ { title: nil, step_given: "G", step_when: "W", step_then: "T", step_expected: "E" } ],
        conditions: [ "il login funziona" ],
        knowledge: [ { id: "page-1", title: "Timeout del gateway" } ]
      )
      allow(Ticketing::ComposeTicket).to receive(:call)
        .with(project:, text: "il login va in timeout", correction: nil, previous_draft: nil)
        .and_return(Result.ok(draft))

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
      expect(request.payload).to include("title" => "Timeout al login", "kind" => "bug",
                                         "description" => "Il login va in timeout dopo 30s.",
                                         "technical_analysis" => "gateway a 30s",
                                         "conditions" => [ "il login funziona" ])
      expect(request.payload["scenarios"].first).to include("step_expected" => "E")
      expect(request.payload["knowledge"]).to eq([ { "id" => "page-1", "title" => "Timeout del gateway" } ])
    end

    # CYRA-632: le richieste già in coda al momento del deploy non portano i due campi nuovi, e non
    # devono morire con una KeyError. Stessa ragione per cui il job legge args[...] e non fetch.
    it "passa la correzione e la bozza precedente quando ci sono" do
      project = create(:project, organization: org)
      previous = { "title" => "Timeout al login", "kind" => "bug", "description" => "Va in timeout." }
      request = create(:ai_request, account:, organization: org, kind: "ticket_compose",
                                    args: { "project_id" => project.id, "text" => "il login va in timeout",
                                            "correction" => "è una story", "previous_draft" => previous })
      allow(Ticketing::ComposeTicket).to receive(:call).and_return(Result.err(AppError.new("x", code: "R502-AI-003")))

      described_class.perform_now(request)

      expect(Ticketing::ComposeTicket).to have_received(:call)
        .with(project:, text: "il login va in timeout", correction: "è una story", previous_draft: previous)
    end
  end

  describe "error_triage" do
    it "scrive il verdetto nel payload" do
      group = create(:error_group, project: create(:project, organization: org))
      request = create(:ai_request, account:, organization: org, kind: "error_triage",
                                    args: { "group_id" => group.id })
      allow(Errors::TriageWithAi).to receive(:call).with(group:).and_return(Result.ok(triage_value))

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
      expect(request.payload).to include("category" => "bug", "severity_suggested" => "high",
                                         "suggested_action" => "resolve")
    end

    it "gruppo di un'ALTRA org → failed (lookup scoped, anti-BOLA difensivo)" do
      foreign_group = create(:error_group)
      request = create(:ai_request, account:, organization: org, kind: "error_triage",
                                    args: { "group_id" => foreign_group.id })

      described_class.perform_now(request)

      expect(request.reload).to be_status_failed
      expect(request.error_code).to eq("R500-SYSTEM-001")
    end
  end

  describe "error_similar" do
    it "scrive reason e gruppi con url" do
      project = create(:project, organization: org)
      group = create(:error_group, project:)
      other = create(:error_group, project:, title: "Altro errore")
      similar = Errors::FindSimilarGroups::Similar.new(groups: [ other ], reason: "stessa causa")
      request = create(:ai_request, account:, organization: org, kind: "error_similar",
                                    args: { "group_id" => group.id })
      allow(Errors::FindSimilarGroups).to receive(:call).with(group:).and_return(Result.ok(similar))

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
      expect(request.payload["reason"]).to eq("stessa causa")
      expect(request.payload["groups"].first).to include("title" => "Altro errore")
      expect(request.payload["groups"].first["url"]).to include(other.id)
    end
  end

  describe "metric_triage" do
    it "scrive il verdetto performance nel payload" do
      group = create(:metric_group, project: create(:project, organization: org))
      value = Metrics::TriageWithAi::Triage.new(
        category: "n_plus_one", severity: "medium", root_cause: "query in loop",
        suggested_fix: "includes(:items)", suggested_action: "promote", confidence: "high", summary: "N+1"
      )
      request = create(:ai_request, account:, organization: org, kind: "metric_triage",
                                    args: { "group_id" => group.id })
      allow(Metrics::TriageWithAi).to receive(:call).with(group:).and_return(Result.ok(value))

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
      expect(request.payload).to include("severity" => "medium", "suggested_fix" => "includes(:items)")
    end
  end

  describe "idea_synthesize" do
    it "scrive la bozza di ticket (title + description) nel payload" do
      idea = create(:idea, organization: org, project: create(:project, organization: org))
      draft = Ideas::SynthesizeTicket::Draft.new(title: "Tema scuro", description: "Sintesi della discussione")
      request = create(:ai_request, account:, organization: org, kind: "idea_synthesize",
                                    args: { "idea_id" => idea.id })
      allow(Ideas::SynthesizeTicket).to receive(:call).with(idea:).and_return(Result.ok(draft))

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
      expect(request.payload).to include("title" => "Tema scuro", "description" => "Sintesi della discussione")
    end

    it "idea di un'ALTRA org → failed (lookup scoped, anti-BOLA difensivo)" do
      foreign_idea = create(:idea)
      request = create(:ai_request, account:, organization: org, kind: "idea_synthesize",
                                    args: { "idea_id" => foreign_idea.id })

      described_class.perform_now(request)

      expect(request.reload).to be_status_failed
      expect(request.error_code).to eq("R500-SYSTEM-001")
    end
  end

  describe "ticket_ask" do
    it "esegue AskTickets sullo scope dei project_ids e scrive answer/insufficient/tickets nel payload" do
      project = create(:project, organization: org)
      sees!(project)
      ticket = create(:ticket, organization: org, project:, title: "Crash login")
      request = create(:ai_request, account:, organization: org, kind: "ticket_ask",
                                    args: { "question" => "problemi col login?", "project_ids" => [ project.id ] })
      answer = Ticketing::AskTickets::Answer.new(answer: "Sì, vedi [#{ticket.code}]",
                                                 tickets: [ ticket ], insufficient: false)
      allow(Ticketing::AskTickets).to receive(:call) do |scope:, question:, organization:|
        expect(scope.to_a).to include(ticket)
        expect(question).to eq("problemi col login?")
        Result.ok(answer)
      end

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
      expect(request.payload).to include("answer" => "Sì, vedi [#{ticket.code}]", "insufficient" => false)
      expect(request.payload["tickets"].first).to include("id" => ticket.id, "code" => ticket.code)
      expect(request.payload["tickets"].first["url"]).to include(ticket.id)
    end

    it "lo scope è ristretto ai project_ids passati (BOLA: niente ticket fuori scope)" do
      visible_project = create(:project, organization: org)
      hidden_project = create(:project, organization: org)
      sees!(visible_project, hidden_project)
      visible_ticket = create(:ticket, organization: org, project: visible_project)
      hidden_ticket = create(:ticket, organization: org, project: hidden_project)
      request = create(:ai_request, account:, organization: org, kind: "ticket_ask",
                                    args: { "question" => "x", "project_ids" => [ visible_project.id ] })
      captured = nil
      allow(Ticketing::AskTickets).to receive(:call) do |scope:, **|
        captured = scope.to_a
        Result.ok(Ticketing::AskTickets::Answer.new(answer: "ok", tickets: [], insufficient: false))
      end

      described_class.perform_now(request)

      expect(captured).to include(visible_ticket)
      expect(captured).not_to include(hidden_ticket)
    end
  end

  describe "knowledge_ask" do
    it "esegue AskPages sullo scope visibile e scrive answer/insufficient/pages nel payload" do
      project = create(:project, organization: org)
      sees!(project)
      page = create(:knowledge_page, :decision, organization: org, project:, title: "Scelta DB")
      request = create(:ai_request, account:, organization: org, kind: "knowledge_ask",
                                    args: { "question" => "che DB?", "full_access" => false,
                                            "project_ids" => [ project.id ], "group_ids" => [] })
      answer = Knowledge::AskPages::Answer.new(answer: "PostgreSQL [Scelta DB]", pages: [ page ], insufficient: false)
      allow(Knowledge::AskPages).to receive(:call) do |scope:, question:, organization:|
        expect(scope.to_a).to include(page)
        expect(question).to eq("che DB?")
        Result.ok(answer)
      end

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
      expect(request.payload).to include("answer" => "PostgreSQL [Scelta DB]", "insufficient" => false)
      expect(request.payload["pages"].first).to include("id" => page.id, "title" => "Scelta DB", "kind_label" => be_present)
      expect(request.payload["pages"].first["url"]).to include(page.id)
    end

    it "full_access: true (owner/god) → scope = tutte le pagine dell'org, indipendente dai link" do
      owner!
      project = create(:project, organization: org)
      page = create(:knowledge_page, organization: org, project:)
      request = create(:ai_request, account:, organization: org, kind: "knowledge_ask",
                                    args: { "question" => "x", "full_access" => true,
                                            "project_ids" => [], "group_ids" => [] })
      captured = nil
      allow(Knowledge::AskPages).to receive(:call) do |scope:, **|
        captured = scope.to_a
        Result.ok(Knowledge::AskPages::Answer.new(answer: "ok", pages: [], insufficient: false))
      end

      described_class.perform_now(request)

      expect(captured).to include(page)
    end

    it "registra la domanda nello storico condiviso con risposta, scope e citazioni (CYRA-421)" do
      project = create(:project, organization: org)
      sees!(project)
      page = create(:knowledge_page, :decision, organization: org, project:, title: "Scelta DB")
      request = create(:ai_request, account:, organization: org, kind: "knowledge_ask",
                                    args: { "question" => "che DB?", "full_access" => false,
                                            "project_ids" => [ project.id ], "group_ids" => [] })
      answer = Knowledge::AskPages::Answer.new(answer: "PostgreSQL", pages: [ page ], insufficient: false)
      allow(Knowledge::AskPages).to receive(:call).and_return(Result.ok(answer))

      expect { described_class.perform_now(request) }.to change(Knowledge::AskLog, :count).by(1)

      log = Knowledge::AskLog.last
      expect(log.account).to eq(account)
      expect(log.question).to eq("che DB?")
      expect(log.answer).to eq("PostgreSQL")
      expect(log.project_ids).to eq([ project.id ])
      expect(log.citations.first).to include("title" => "Scelta DB")
    end

    it "registra nello storico anche una risposta insufficiente, senza testo (CYRA-421)" do
      request = create(:ai_request, account:, organization: org, kind: "knowledge_ask",
                                    args: { "question" => "?", "full_access" => false,
                                            "project_ids" => [], "group_ids" => [] })
      allow(Knowledge::AskPages).to receive(:call)
        .and_return(Result.ok(Knowledge::AskPages::Answer.new(answer: nil, pages: [], insufficient: true)))

      described_class.perform_now(request)

      log = Knowledge::AskLog.last
      expect(log.insufficient).to be(true)
      expect(log.answer).to be_nil
    end

    it "un fallimento nel salvare lo storico non ribalta una risposta già consegnata (CYRA-421)" do
      request = create(:ai_request, account:, organization: org, kind: "knowledge_ask",
                                    args: { "question" => "x", "full_access" => false,
                                            "project_ids" => [], "group_ids" => [] })
      allow(Knowledge::AskPages).to receive(:call)
        .and_return(Result.ok(Knowledge::AskPages::Answer.new(answer: "ok", pages: [], insufficient: false)))
      allow(Knowledge::AskLog).to receive(:record!).and_raise(StandardError, "db giù")

      described_class.perform_now(request)

      expect(request.reload).to be_status_done
    end
  end

  # CYRA-812 — stesso difetto del canale a terminale: il perimetro salvato all'invio è un tetto, non
  # un lasciapassare. Fra il click e l'esecuzione l'accesso può essere stato tolto.
  describe "quando l'accesso cambia fra la domanda e l'esecuzione" do
    def asks(kind, args)
      create(:ai_request, account:, organization: org, kind: kind, args: args)
    end

    def captured_scope_for(service)
      captured = nil
      allow(service).to receive(:call) do |scope:, **|
        captured = scope.to_a
        Result.ok(answer_for(service))
      end
      yield
      captured
    end

    def answer_for(service)
      if service == Ticketing::AskTickets
        Ticketing::AskTickets::Answer.new(answer: "ok", tickets: [], insufficient: false)
      else
        Knowledge::AskPages::Answer.new(answer: "ok", pages: [], insufficient: false)
      end
    end

    it "non legge i ticket del progetto revocato dopo l'invio" do
      project = create(:project, organization: org)
      sees!(project)
      ticket = create(:ticket, organization: org, project:)
      request = asks("ticket_ask", { "question" => "x", "project_ids" => [ project.id ] })
      Connections::ProjectMembership.find_by(account: account, project: project).destroy!

      captured = captured_scope_for(Ticketing::AskTickets) { described_class.perform_now(request) }

      expect(captured).not_to include(ticket)
    end

    it "non legge le pagine del progetto revocato dopo l'invio" do
      project = create(:project, organization: org)
      sees!(project)
      page = create(:knowledge_page, organization: org, project:)
      request = asks("knowledge_ask", { "question" => "x", "full_access" => false,
                                        "project_ids" => [ project.id ], "group_ids" => [] })
      Connections::ProjectMembership.find_by(account: account, project: project).destroy!

      captured = captured_scope_for(Knowledge::AskPages) { described_class.perform_now(request) }

      expect(captured).not_to include(page)
    end

    it "chiude la porta della knowledge base a chi non è più owner" do
      membership = owner!
      project = create(:project, organization: org)
      page = create(:knowledge_page, organization: org, project:)
      request = asks("knowledge_ask", { "question" => "x", "full_access" => true,
                                        "project_ids" => [], "group_ids" => [] })
      membership.update!(role: :member)

      captured = captured_scope_for(Knowledge::AskPages) { described_class.perform_now(request) }

      expect(captured).not_to include(page)
    end

    it "non raccoglie i ticket del progetto nato dopo l'invio, nemmeno per l'owner" do
      owner!
      request = asks("ticket_ask", { "question" => "x", "project_ids" => [], "scope_listed" => true })
      ticket = create(:ticket, organization: org, project: create(:project, organization: org))

      captured = captured_scope_for(Ticketing::AskTickets) { described_class.perform_now(request) }

      expect(captured).not_to include(ticket)
    end

    # Sulla knowledge base l'accesso pieno vuol dire ORGANIZZAZIONE, non un elenco: le pagine non
    # appartengono a un progetto e quelle valide per tutti non ne hanno nessuno. Restringere qui
    # all'elenco toglierebbe all'owner proprio quelle, quindi il perimetro resta l'organizzazione —
    # ed è stabile, perché il permesso non è cambiato. Quello che l'elenco protegge è la lettura per
    # id (ticket e progetti), dove un progetto nuovo si aggiungerebbe davvero al perimetro.
    it "con l'accesso pieno la knowledge base resta quella dell'organizzazione" do
      owner!
      request = asks("knowledge_ask", { "question" => "x", "full_access" => true, "scope_listed" => true,
                                        "project_ids" => [], "group_ids" => [] })
      page = create(:knowledge_page, organization: org, project: create(:project, organization: org))

      captured = captured_scope_for(Knowledge::AskPages) { described_class.perform_now(request) }

      expect(captured).to include(page)
    end

    # L'identità che conta è quella che ha autorizzato la domanda: un god che impersona un membro
    # aveva il perimetro del god, e ricalcolarlo sull'impersonato lo restringerebbe per sbaglio.
    it "ricalcola sul god che ha impersonato, non sull'account impersonato" do
      god = create(:account, god: true)
      project = create(:project, organization: org)
      ticket = create(:ticket, organization: org, project:)
      request = asks("ticket_ask", { "question" => "x", "project_ids" => [ project.id ],
                                     "actor_account_id" => god.id })

      captured = captured_scope_for(Ticketing::AskTickets) { described_class.perform_now(request) }

      expect(captured).to include(ticket)
    end

    # CYRA-831 Scenario 2 — la revoca può arrivare su un GRUPPO di progetti, non su un progetto solo.
    # Il gruppo è la maniglia con cui si dà e si toglie l'accesso a più progetti insieme, e una pagina
    # può essere agganciata al gruppo senza passare da nessun progetto: se l'intersezione guardasse i
    # soli progetti, quelle pagine resterebbero leggibili a chi il gruppo non ce l'ha più.
    it "non usa le pagine del gruppo revocato dopo l'invio" do
      create(:membership, account: account, organization: org, role: :member)
      group = create(:group, organization: org)
      membership = create(:group_membership, account: account, group: group)
      page = create(:knowledge_page, organization: org, scoped: false)
      page.groups << group
      request = asks("knowledge_ask", { "question" => "x", "full_access" => false, "scope_listed" => true,
                                        "project_ids" => [], "group_ids" => [ group.id ] })
      membership.destroy!

      captured = captured_scope_for(Knowledge::AskPages) { described_class.perform_now(request) }

      expect(captured).not_to include(page)
    end

    it "registra nello storico il perimetro su cui ha risposto davvero, non quello dell'invio" do
      project = create(:project, organization: org)
      sees!(project)
      request = asks("knowledge_ask", { "question" => "x", "full_access" => false,
                                        "project_ids" => [ project.id ], "group_ids" => [] })
      Connections::ProjectMembership.find_by(account: account, project: project).destroy!
      allow(Knowledge::AskPages).to receive(:call)
        .and_return(Result.ok(Knowledge::AskPages::Answer.new(answer: "ok", pages: [], insufficient: false)))

      described_class.perform_now(request)

      expect(Knowledge::AskLog.last.project_ids).to be_empty
    end
  end

  # CYRA-831 — la risposta ristretta si DICHIARA. Il perimetro ripassato (CYRA-812) protegge il dato,
  # ma da solo consegna in silenzio una risposta più povera di quella che chi ha chiesto si aspetta:
  # senza una nota, "nessun ticket pertinente" si legge come un fatto sull'archivio invece che come
  # un effetto di un accesso tolto nel frattempo. Sul canale a terminale lo dice il modello, istruito
  # dal prompt; qui la risposta la scrive un service e la nota è un dato del risultato, sempre
  # presente, così la pagina la rende senza doverla cercare nel testo.
  describe "la nota sul perimetro ridotto (CYRA-831)" do
    def asks(kind, args)
      create(:ai_request, account:, organization: org, kind: kind, args: args)
    end

    def answers!(service)
      value = if service == Ticketing::AskTickets
                Ticketing::AskTickets::Answer.new(answer: "ok", tickets: [], insufficient: false)
      else
                Knowledge::AskPages::Answer.new(answer: "ok", pages: [], insufficient: false)
      end
      allow(service).to receive(:call).and_return(Result.ok(value))
    end

    it "domanda sui ticket: il progetto revocato dopo l'invio si dichiara nel risultato" do
      project = create(:project, organization: org)
      sees!(project)
      request = asks("ticket_ask", { "question" => "x", "scope_listed" => true,
                                     "project_ids" => [ project.id ], "group_ids" => [] })
      Connections::ProjectMembership.find_by(account: account, project: project).destroy!
      answers!(Ticketing::AskTickets)

      described_class.perform_now(request)

      expect(request.reload.payload).to include("scope_reduced" => true)
    end

    it "domanda sui ticket: perimetro invariato → nessuna nota" do
      project = create(:project, organization: org)
      sees!(project)
      request = asks("ticket_ask", { "question" => "x", "scope_listed" => true,
                                     "project_ids" => [ project.id ], "group_ids" => [] })
      answers!(Ticketing::AskTickets)

      described_class.perform_now(request)

      expect(request.reload.payload).to include("scope_reduced" => false)
    end

    it "domanda sulla knowledge base: il gruppo revocato dopo l'invio si dichiara nel risultato" do
      create(:membership, account: account, organization: org, role: :member)
      group = create(:group, organization: org)
      membership = create(:group_membership, account: account, group: group)
      request = asks("knowledge_ask", { "question" => "x", "full_access" => false, "scope_listed" => true,
                                        "project_ids" => [], "group_ids" => [ group.id ] })
      membership.destroy!
      answers!(Knowledge::AskPages)

      described_class.perform_now(request)

      expect(request.reload.payload).to include("scope_reduced" => true)
    end

    it "domanda sulla knowledge base: perimetro invariato → nessuna nota" do
      create(:membership, account: account, organization: org, role: :member)
      group = create(:group, organization: org)
      create(:group_membership, account: account, group: group)
      request = asks("knowledge_ask", { "question" => "x", "full_access" => false, "scope_listed" => true,
                                        "project_ids" => [], "group_ids" => [ group.id ] })
      answers!(Knowledge::AskPages)

      described_class.perform_now(request)

      expect(request.reload.payload).to include("scope_reduced" => false)
    end

    # La nota vale ANCHE quando non è rimasto niente da leggere: è proprio il caso in cui tacere
    # inganna di più, perché la risposta vuota si legge come un fatto sull'archivio.
    it "vale anche sulla risposta che non ha trovato niente" do
      project = create(:project, organization: org)
      sees!(project)
      request = asks("ticket_ask", { "question" => "x", "scope_listed" => true,
                                     "project_ids" => [ project.id ], "group_ids" => [] })
      Connections::ProjectMembership.find_by(account: account, project: project).destroy!
      allow(Ticketing::AskTickets).to receive(:call).and_return(
        Result.ok(Ticketing::AskTickets::Answer.new(answer: "", tickets: [], insufficient: true))
      )

      described_class.perform_now(request)

      expect(request.reload.payload).to include("insufficient" => true, "scope_reduced" => true)
    end

    # Gli altri kind non portano un perimetro: il campo non deve comparire nel loro risultato, o il
    # client si troverebbe a distinguere «non ridotto» da «non pertinente» leggendo lo stesso false.
    it "gli altri kind non portano la nota" do
      group = create(:error_group, project: create(:project, organization: org))
      request = create(:ai_request, account:, organization: org, kind: "error_triage",
                                    args: { "group_id" => group.id })
      allow(Errors::TriageWithAi).to receive(:call).and_return(Result.ok(triage_value))

      described_class.perform_now(request)

      expect(request.reload.payload).not_to have_key("scope_reduced")
    end
  end

  describe "esiti di errore" do
    it "Result.err del service → failed con codice e messaggio del gateway" do
      group = create(:error_group, project: create(:project, organization: org))
      request = create(:ai_request, account:, organization: org, kind: "error_triage",
                                    args: { "group_id" => group.id })
      allow(Errors::TriageWithAi).to receive(:call)
        .and_return(Result.err(AppError.new("gateway giù", code: "R502-AI-001", status: :bad_gateway)))

      described_class.perform_now(request)

      expect(request.reload).to be_status_failed
      expect(request.error_code).to eq("R502-AI-001")
      expect(request.error_message).to eq("gateway giù")
    end

    it "eccezione inattesa → failed R500-SYSTEM-001, nessun raise" do
      group = create(:error_group, project: create(:project, organization: org))
      request = create(:ai_request, account:, organization: org, kind: "error_triage",
                                    args: { "group_id" => group.id })
      allow(Errors::TriageWithAi).to receive(:call).and_raise(RuntimeError, "boom")

      expect { described_class.perform_now(request) }.not_to raise_error

      expect(request.reload).to be_status_failed
      expect(request.error_code).to eq("R500-SYSTEM-001")
    end
  end
end
