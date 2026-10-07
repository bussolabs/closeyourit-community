# frozen_string_literal: true

require "rails_helper"

# Gli attrezzi dell'assistente. Il tema centrale di questi test non è il formato della risposta ma il
# CONFINE: qualunque cosa il modello chieda, deve poter leggere solo dentro il perimetro congelato.
RSpec.describe "Assistant::Tools" do
  let(:organization) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:project) { create(:project, organization: organization, key: "CYRA", name: "closeyourit-rails") }
  # Progetto reale ma FUORI dal perimetro: è il caso da cui dipende tutta la sicurezza.
  let(:altrui) { create(:project, organization: organization, key: "SEGR", name: "progetto-riservato") }
  let(:context) do
    Assistant::Tools::Context.new(account: account, organization: organization,
                                  project_ids: [ project.id ], group_ids: [], full_access: false)
  end

  def run(name, args = {})
    Assistant::Tools::Registry.run(name: name, args: args, context: context)
  end

  describe "il perimetro congelato" do
    it "trova un progetto dentro il perimetro per chiave, anche scritta in minuscolo" do
      expect(context.find_project("cyra")).to eq(project)
    end

    it "non trova un progetto fuori dal perimetro, benché esista" do
      expect(altrui).to be_persisted
      expect(context.find_project("SEGR")).to be_nil
    end

    # Chi scrive nomina il progetto come gli viene, spesso col nome e non con la chiave: ripiegare
    # sul nome evita che una domanda legittima finisca in "non lo trovo".
    it "trova un progetto anche da un pezzo del suo nome" do
      expect(context.find_project("closeyourit")).to eq(project)
    end

    it "risponde nulla a un riferimento vuoto invece di prendere il primo che capita" do
      expect(context.find_project("  ")).to be_nil
    end

    it "non restituisce i ticket dei progetti fuori dal perimetro" do
      create(:ticket, project: altrui, organization: organization)
      dentro = create(:ticket, project: project, organization: organization)

      expect(context.tickets.pluck(:id)).to eq([ dentro.id ])
    end

    # Il perimetro si fissa all'invio della domanda: quello che nasce dopo non entra in una
    # conversazione già partita, e gli attrezzi leggono sempre lo stesso insieme dal primo giro
    # all'ultimo.
    it "resta fermo sui progetti visibili al momento della domanda" do
      congelato = Assistant::Tools::Context.freeze_for(account: account, organization: organization)
      prima = congelato.project_ids

      create(:project, organization: organization, key: "NEW")

      expect(congelato.project_ids).to eq(prima)
      expect(congelato.projects.pluck(:id)).to eq(prima)
    end
  end

  describe "list_projects" do
    it "elenca solo i progetti visibili" do
      altrui # esiste ma è fuori

      result = run("list_projects")

      expect(result[:projects]).to eq([ { key: "CYRA", name: "closeyourit-rails" } ])
    end
  end

  describe "search_tickets" do
    it "filtra per categoria di stato, non per il codice dello stato" do
      in_review = create(:ticket_status, organization: organization, code: "in_review", category: :in_progress)
      create(:ticket, project: project, organization: organization, title: "in revisione", status: in_review)
      create(:ticket, project: project, organization: organization, title: "da fare",
                      status: create(:ticket_status, organization: organization, code: "open", category: :open))

      titoli = run("search_tickets", "project" => "CYRA", "status" => "in_progress")[:tickets].pluck(:title)

      expect(titoli).to eq([ "in revisione" ])
    end

    it "dice che il progetto non è visibile invece di cercare altrove" do
      create(:ticket, project: altrui, organization: organization)

      expect(run("search_tickets", "project" => "SEGR")[:error]).to include("No visible project matches SEGR").and include("ask which one")
    end

    it "restituisce i soli ticket dell'utente quando glielo si chiede" do
      create(:ticket, project: project, organization: organization, title: "di altri")
      create(:ticket, project: project, organization: organization, title: "mio", assignee: account)

      titoli = run("search_tickets", "project" => "CYRA", "mine" => true)[:tickets].pluck(:title)

      expect(titoli).to eq([ "mio" ])
    end

    # Uno stato inventato dal modello non deve diventare un filtro SQL: si ignora e si risponde con
    # l'elenco intero, che è un dato vero, invece di sollevare a metà conversazione.
    it "ignora uno stato che non esiste invece di sollevare" do
      create(:ticket, project: project, organization: organization, title: "unico")

      expect(run("search_tickets", "project" => "CYRA", "status" => "inventato")[:tickets].size).to eq(1)
    end
  end

  describe "get_ticket" do
    it "risolve il ticket dal codice umano CYRA-1" do
      ticket = create(:ticket, project: project, organization: organization, title: "il primo")

      expect(run("get_ticket", "code" => ticket.code)[:title]).to eq("il primo")
    end

    it "non legge un ticket di un progetto fuori dal perimetro" do
      fuori = create(:ticket, project: altrui, organization: organization)

      expect(run("get_ticket", "code" => fuori.code)[:error]).to include("Nessun ticket visibile")
    end

    it "non solleva su un codice senza senso" do
      expect(run("get_ticket", "code" => "non-un-codice")[:error]).to be_present
    end

    # L'assegnatario è facoltativo: un ticket appena aperto e non ancora preso in carico non deve far
    # cadere l'attrezzo, deve arrivare al modello col campo vuoto.
    it "non cade su un ticket che non è ancora di nessuno" do
      ticket = create(:ticket, project: project, organization: organization, assignee: nil)

      result = run("get_ticket", "code" => ticket.code)

      expect(result[:assignee]).to be_nil
      expect(result[:title]).to eq(ticket.title)
    end

    # I commenti recenti sono metà del senso di "a che punto è": senza, il modello vede lo stato ma
    # non cosa è stato detto. Restano pochi e clampati, che è ciò che li tiene sostenibili.
    it "porta gli ultimi commenti, con chi li ha scritti" do
      ticket = create(:ticket, project: project, organization: organization)
      create(:ticket_comment, ticket: ticket, author: account, body: "ci sto guardando")

      commenti = run("get_ticket", "code" => ticket.code)[:comments]

      expect(commenti.first[:body]).to eq("ci sto guardando")
      expect(commenti.first[:author]).to eq(account.name)
    end
  end

  describe "project_health" do
    it "conta i ticket per categoria, gli errori non risolti e i monitor giù" do
      create(:ticket, project: project, organization: organization,
                      status: create(:ticket_status, organization: organization, code: "open", category: :open))
      create(:error_group, project: project, status: :unresolved)
      create(:error_group, project: project, status: :resolved)
      create(:uptime_monitor, project: project, name: "sito", active: true, current_status: :down)
      create(:uptime_monitor, project: project, name: "in pausa", active: false, current_status: :down)

      result = run("project_health", "project" => "CYRA")

      expect(result[:tickets][:da_fare]).to eq(1)
      expect(result[:errori_non_risolti]).to eq(1)
      expect(result[:monitor_giu]).to eq([ "sito" ])
    end

    it "non riassume un progetto fuori dal perimetro" do
      expect(run("project_health", "project" => "SEGR")[:error]).to include("No visible project matches SEGR").and include("ask which one")
    end
  end

  # Il rilievo che ha fatto emergere il buco: le pagine NON hanno un project_id — stanno su più
  # progetti e più gruppi. Il filtro sbagliato non dava zero risultati: sollevava un errore SQL, e
  # ask_knowledge era l'unico dei sei attrezzi mai provato a mano.
  describe "ask_knowledge e il perimetro della conoscenza" do
    it "interroga le pagine senza esplodere sulla relazione a più progetti" do
      create(:knowledge_page, project: project, title: "Come si rilascia")

      expect { context.knowledge_pages.to_a }.not_to raise_error
      expect(context.knowledge_pages.pluck(:title)).to include("Come si rilascia")
    end

    it "non mostra le pagine dei progetti fuori dal perimetro" do
      create(:knowledge_page, project: altrui, title: "Segreta")

      expect(context.knowledge_pages.pluck(:title)).not_to include("Segreta")
    end

    # Chi ha accesso pieno vede anche le pagine che non stanno su nessun progetto: il perimetro le
    # perderebbe, perché di progetti da elencare non ne hanno.
    it "con accesso pieno vede anche le pagine non legate ad alcun progetto" do
      create(:knowledge_page, :org_wide, organization: organization, title: "Vale per tutti")
      pieno = Assistant::Tools::Context.new(account: account, organization: organization,
                                            project_ids: [], group_ids: [], full_access: true)

      expect(pieno.knowledge_pages.pluck(:title)).to include("Vale per tutti")
    end
  end

  # I due attrezzi che cercano per SIGNIFICATO non rifanno il RAG: gli passano lo scope congelato e
  # ne riducono l'esito a un Hash piccolo. Quello che torna al modello sono la risposta e le FONTI,
  # perché è con quelle che poi cita, e senza citazione una risposta non è verificabile.
  describe "ask_tickets e ask_knowledge quando la ricerca risponde" do
    it "riporta la risposta e i ticket su cui si fonda" do
      ticket = create(:ticket, project: project, organization: organization, title: "login lento")
      trovato = Ticketing::AskTickets::Answer.new(answer: "Sì, ne parla [#{ticket.code}].",
                                                 tickets: [ ticket ], insufficient: false)
      allow(Ticketing::AskTickets).to receive(:call).and_return(Result.ok(trovato))

      result = run("ask_tickets", "question" => "problemi di login?")

      expect(result[:answer]).to include(ticket.code)
      expect(result[:tickets]).to eq([ { code: ticket.code, title: "login lento" } ])
    end

    it "riporta la risposta e le pagine su cui si fonda" do
      page = create(:knowledge_page, project: project, title: "Come si rilascia")
      trovata = Knowledge::AskPages::Answer.new(answer: "Si rilascia da un tag.",
                                                pages: [ page ], insufficient: false)
      allow(Knowledge::AskPages).to receive(:call).and_return(Result.ok(trovata))

      result = run("ask_knowledge", "question" => "come si rilascia?")

      expect(result[:answer]).to eq("Si rilascia da un tag.")
      expect(result[:pages]).to eq([ { title: "Come si rilascia" } ])
    end

    it "riporta il contesto insufficiente della knowledge base senza inventare" do
      vuota = Knowledge::AskPages::Answer.new(answer: nil, pages: [], insufficient: true)
      allow(Knowledge::AskPages).to receive(:call).and_return(Result.ok(vuota))

      expect(run("ask_knowledge", "question" => "e questo?")[:insufficient]).to be(true)
    end
  end

  # Quando la ricerca semantica è giù (o spenta dal pannello) la risposta deve dirlo: un attrezzo
  # muto farebbe rispondere il modello a vuoto, che è il guasto che questa riga esiste per impedire.
  describe "quando la ricerca semantica è giù" do
    it "ask_tickets riporta l'errore invece di restituire il vuoto" do
      allow(Ticketing::AskTickets).to receive(:call)
        .and_return(Result.err(AppError.new("Servizio embedding non raggiungibile", code: "R502-EMBED-001")))

      expect(run("ask_tickets", "question" => "com'è il login?")[:error])
        .to include("Servizio embedding non raggiungibile")
    end

    it "ask_knowledge riporta l'errore invece di restituire il vuoto" do
      allow(Knowledge::AskPages).to receive(:call)
        .and_return(Result.err(AppError.new("Servizio embedding non raggiungibile", code: "R502-EMBED-001")))

      expect(run("ask_knowledge", "question" => "come si rilascia?")[:error]).to be_present
    end

    # "Non ne so abbastanza" è una risposta onesta del RAG (zero candidati sopra soglia, nessuna
    # chiamata al modello): va riportata così com'è, non mascherata da risposta vuota.
    it "riporta il contesto insufficiente invece di inventare una risposta" do
      insufficiente = Ticketing::AskTickets::Answer.new(answer: nil, tickets: [], insufficient: true)
      allow(Ticketing::AskTickets).to receive(:call).and_return(Result.ok(insufficiente))

      result = run("ask_tickets", "question" => "cosa sappiamo dei pagamenti?")

      expect(result[:insufficient]).to be(true)
      expect(result[:answer]).to be_nil
    end

    # Il RAG riceve lo scope congelato, non ricalcola la visibilità per conto suo: è lì che vive il
    # confine, e un secondo calcolo darebbe il perimetro di un altro momento.
    it "passa al RAG lo scope congelato del perimetro" do
      allow(Ticketing::AskTickets).to receive(:call)
        .and_return(Result.ok(Ticketing::AskTickets::Answer.new(answer: "ok", tickets: [], insufficient: false)))

      run("ask_tickets", "question" => "e allora?")

      expect(Ticketing::AskTickets).to have_received(:call) do |scope:, question:, organization:|
        expect(scope.to_sql).to include(project.id)
        expect(question).to eq("e allora?")
        # CYRA-547 — il RAG deve sapere anche CHI paga la risposta, o costruirebbe il client senza chiave.
        expect(organization).to eq(self.organization)
      end
    end
  end

  describe "quando i progetti sono più di quanti se ne mostrano" do
    it "dichiara il totale vero e dice che l'elenco è tagliato" do
      stub_const("Assistant::Tools::Base::MAX_ROWS", 2)
      project # il progetto del perimetro, più altri tre
      3.times { |i| create(:project, organization: organization, key: "PR#{i}") }
      tutti = Assistant::Tools::Context.new(account: account, organization: organization,
                                            project_ids: Projects::Project.pluck(:id),
                                            group_ids: [], full_access: false)

      result = Assistant::Tools::Registry.run(name: "list_projects", args: {}, context: tutti)

      expect(result[:projects].size).to eq(2)
      expect(result[:total]).to eq(4)
      expect(result[:troncato]).to include("of 4").and include("may still exist")
    end
  end

  describe "il registro" do
    it "dichiara tutti gli attrezzi in un solo blocco, come vuole il provider" do
      declarations = Assistant::Tools::Registry.declarations(context)

      expect(declarations.size).to eq(1)
      expect(declarations.first[:functionDeclarations].pluck(:name))
        .to match_array(%w[list_projects search_tickets get_ticket ask_tickets ask_knowledge project_health
                              list_errors list_performance search_logs list_monitors list_releases list_ideas])
    end

    # Il modello può inventare un nome: la conversazione deve proseguire, non morire.
    it "risponde con un errore leggibile a un attrezzo inventato" do
      expect(run("vola_sulla_luna")[:error]).to include("sconosciuto")
    end

    # In sola lettura, per intero: un attrezzo che scrive va in un elenco separato e dietro una
    # conferma esplicita di chi sta chiedendo, non aggiunto qui.
    it "non espone alcun attrezzo che scriva" do
      nomi = Assistant::Tools::Registry.declarations(context).first[:functionDeclarations].pluck(:name)

      expect(nomi).to all(match(/\A(list|search|get|ask|project)_/))
    end
  end
end
