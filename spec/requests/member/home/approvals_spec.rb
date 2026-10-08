# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Home::Approvals", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def review_ticket(reviewer: owner, project: self.project, **attributes)
    create(:ticket, organization: org, project: project,
                    status: create(:ticket_status, :in_review, organization: org), reviewer: reviewer, **attributes)
  end

  # Lavorazione ferma davvero (CYRA-267): il triage è stato claimato, la revisione l'ha respinto e la
  # coda non lo ripropone più. Nessun blocked_at: il tetto dei tentativi non è stato raggiunto.
  def stalled_workflow(review: nil)
    ticket = create(:ticket, organization: org, project: project)
    create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triage_started_at: 1.day.ago).tap do |workflow|
      create(:agent_attempt, workflow:, organization: org, phase: "triage", status: :review_failed,
                             review: review.present? ? { "summary" => review } : {},
                             review_status: (:changes_requested if review.present?))
    end
  end

  # Lavorazione che RIPROVA DA SOLA (CYRA-317): la revisione ha respinto il planner, che non ha un
  # avvio dedicato e torna reclamabile da sé. Non aspetta nessuno: vive nell'elenco separato.
  def retrying_workflow(review: nil)
    ticket = create(:ticket, organization: org, project: project)
    create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triage_started_at: 1.day.ago,
                            triaged_at: 1.day.ago).tap do |workflow|
      create(:agent_attempt, workflow:, organization: org, phase: "planner", status: :review_failed,
                             review: review.present? ? { "summary" => review } : {},
                             review_status: (:changes_requested if review.present?))
    end
  end

  describe "GET index" do
    # CYRA-592 — senza `?item=` si guarda la plancia, non una richiesta aperta d'ufficio: con una
    # tabella su cui si sceglie dove guardare, aprirne una a caso deciderebbe al posto di chi guarda.
    it "mostra la plancia e non apre nessuna richiesta da sola" do
      ticket = review_ticket(title: "Da revisionare")
      sign_in(owner)

      get member_home_approvals_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="approvals-board"')
      expect(response.body).to include(ticket.code)
      expect(response.body).not_to include('data-test="approvals-detail"')
    end

    # CYRA-592/619 — le SEI colonne ci sono SEMPRE tutte, anche quelle non ancora raggiunte. Con una
    # riga a sei celle e un'altra a due, la lettura in verticale salterebbe.
    it "ogni riga porta i sei passaggi, compresi quelli futuri" do
      review_ticket(title: "Da revisionare")
      sign_in(owner)

      get member_home_approvals_path

      riga = Nokogiri::HTML(response.body).at_css("[data-test='approvals-board-row']")
      Agents::Workflows::PhaseResolver::STEPS.each do |step|
        expect(riga.at_css("[data-test='approvals-board-cell-#{step}']")).to be_present
      end
    end

    # CYRA-316 (riletto da CYRA-592) — a che punto è la lavorazione si legge senza aprire il ticket:
    # prima lo diceva il badge dello stato accanto alla sigla, ora lo dicono le cinque celle — che
    # dicono anche quanta strada manca — e la colonna «Stato».
    it "ogni riga dice a che punto è la lavorazione e cosa sta aspettando" do
      ticket = create(:ticket, organization: org, project:)
      create(:agent_workflow, ticket:, triage_requested_at: 3.hours.ago, triage_started_at: 3.hours.ago,
                              triaged_at: 2.hours.ago, planned_at: 1.hour.ago)
      sign_in(owner)

      get member_home_approvals_path

      riga = Nokogiri::HTML(response.body).at_css("[data-test='approvals-board-row']")
      expect(riga.at_css("[data-test='approvals-board-cell-to_plan']")["data-state"]).to eq("done")
      expect(riga.at_css("[data-test='approvals-board-cell-plan_to_approve']")["data-state"]).to eq("current")
      expect(riga.at_css("[data-test='approvals-board-cell-done']")["data-state"]).to eq("pending")
      expect(riga.at_css("[data-test='approvals-board-state']").text.strip)
        .to eq(I18n.t("member.approvals.filters.awaiting_approval"))
    end

    # CYRA-619 — la cella apre il PASSAGGIO dentro il ticket, non il referto di un singolo tentativo
    # della macchina: quello è un oggetto interno, a volte l'ultimo di diciannove, e non dice a che
    # punto è il lavoro.
    it "apre il passaggio dentro il ticket, non il referto di un tentativo" do
      ticket = create(:ticket, organization: org, project:)
      create(:agent_workflow, ticket:, triage_requested_at: 3.hours.ago,
                              triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago,
                              planned_at: 1.hour.ago)
      sign_in(owner)

      get member_home_approvals_path

      riga = Nokogiri::HTML(response.body).at_css("[data-test='approvals-board-row']")
      link = riga.at_css("[data-test='approvals-board-cell-to_plan'] a")
      expect(link["href"]).to eq(member_ticket_path(ticket, tab: "automation", anchor: "passaggio-to_plan"))
      expect(link["href"]).not_to include("attempt-")
    end

    # CYRA-899 — the groups are the kinds of decision, each with its count and a header that opens
    # and closes; the project moved onto the row.
    it "groups rows by what the decision asks, with how many it holds" do
      allow_n_plus_one do
        2.times { |i| review_ticket(title: "To review #{i}") }
        create(:agent_workflow, ticket: create(:ticket, organization: org, project:), planned_at: Time.current)
      end
      sign_in(owner)

      get member_home_approvals_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-test='approvals-board-group']").size).to eq(2)
      expect(doc.at_css("[data-test='approvals-board-group-awaiting_approval']")).to be_present
      expect(doc.at_css("[data-test='approvals-board-group-review']").text)
        .to include(I18n.t("member.approvals.filters.review"))
        .and include(I18n.t("member.approvals.board.group_count", count: 2))
    end

    # Il gruppo si apre e si chiude: l'intestazione è un bottone che dichiara di essere aperta, e le
    # sue righe sono agganciate a lui per sigla. Senza JS restano tutte visibili, che è il caso in
    # cui questa spec gira: qui si verifica che il filo ci sia.
    it "l'intestazione del progetto si può chiudere, e sa quali righe si porta dietro" do
      review_ticket(title: "Da revisionare")
      sign_in(owner)

      get member_home_approvals_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='approvals-board'] [data-controller~='ui--row-group']")).to be_present
      intestazione = doc.at_css("[data-test='approvals-board-group-review']")
      expect(intestazione["aria-expanded"]).to eq("true")
      expect(intestazione["data-ui--row-group-key-param"]).to eq("review")
      expect(doc.at_css("[data-test='approvals-board-row']")["data-row-group-key"]).to eq("review")
    end

    it "sceglie quante righe vedere per pagina" do
      allow_n_plus_one { 3.times { |i| review_ticket(title: "Ticket #{i}") } }
      sign_in(owner)

      get member_home_approvals_path(per: 2)

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-test='approvals-board-row']").size).to eq(2)
      expect(doc.at_css("[data-test='pagination-per-100']")).to be_present
    end

    it "sulla seconda pagina mostra le righe rimaste" do
      allow_n_plus_one { 3.times { |i| review_ticket(title: "Ticket #{i}") } }
      sign_in(owner)

      get member_home_approvals_path(per: 2, page: 2)

      expect(Nokogiri::HTML(response.body).css("[data-test='approvals-board-row']").size).to eq(1)
    end

    it "il pulsante della riga apre proprio quella richiesta" do
      ticket = review_ticket(title: "Da revisionare")
      sign_in(owner)

      get member_home_approvals_path

      pulsante = Nokogiri::HTML(response.body).at_css("[data-test='approvals-board-decide']")
      expect(pulsante["href"]).to eq(member_home_approvals_path(item: "review:#{ticket.id}"))
    end

    # CYRA-592 — la plancia cambia la RESA, non chi vede cosa: le righe restano quelle della coda,
    # coi suoi gate. Approvare il piano di un agente è del CTO effettivo del progetto; a chi vede lo
    # stesso ticket ma non può decidere quella riga non deve comparire.
    it "nella plancia restano solo le decisioni che chi guarda può prendere" do
      altro = create(:account)
      create(:membership, account: altro, organization: org, role: :member)
      # Vede il progetto (assegnazione), quindi vede entrambi i ticket: quello che non compare, non
      # compare per il gate della decisione, non perché il ticket gli sia invisibile.
      create(:project_membership, account: altro, project:)
      mia = review_ticket(reviewer: altro, title: "Tocca a me")
      del_cto = create(:ticket, organization: org, project:, title: "Piano del CTO")
      create(:agent_workflow, ticket: del_cto, planned_at: 1.hour.ago)
      sign_in(altro)

      get member_home_approvals_path

      expect(response.body).to include(mia.code)
      expect(response.body).not_to include(del_cto.code)
    end

    # CYRA-303 — con decine di righe il tipo di richiesta era ripetuto identico su ognuna, mentre
    # codice e titolo del ticket — le sole informazioni che distinguono una riga dall'altra — stavano
    # in secondo piano. Ora la riga si apre con codice + titolo, e il tipo è un'etichetta breve.
    describe "gerarchia della riga (CYRA-303)" do
      it "ogni riga si apre con il codice del ticket e il suo titolo vero" do
        ticket = review_ticket(title: "Il salvataggio va in errore")
        sign_in(owner)

        get member_home_approvals_path

        cella = Nokogiri::HTML(response.body).at_css("[data-test='approvals-board-ticket']")
        expect(cella.text).to include(ticket.code)
        expect(cella.text).to include("Il salvataggio va in errore")
      end

      # CYRA-592 — lo STATO è una colonna sua, con testo allineato: dentro la cella del ticket
      # sarebbe un'etichetta colorata in mezzo ai puntini, e la colonna delle fasi non si leggerebbe
      # più dall'alto in basso.
      it "il tipo di richiesta sta nella sua colonna, non dentro il titolo" do
        review_ticket(title: "Il salvataggio va in errore")
        sign_in(owner)

        get member_home_approvals_path

        riga = Nokogiri::HTML(response.body).at_css("[data-test='approvals-board-row']")
        stato = riga.at_css("[data-test='approvals-board-state']")
        expect(stato.text.strip).to eq(I18n.t("member.approvals.filters.review"))
        expect(riga.at_css("[data-test='approvals-board-ticket']").text).not_to include(stato.text.strip)
      end

      # I nomi delle fasi stanno SOLO nelle intestazioni: ripetuti su ogni riga scriverebbero la
      # stessa parola centodieci volte. Restano però nel testo per i lettori di schermo — una griglia
      # di puntini senza il nome del passaggio sarebbe muta per chi non vede i colori — quindi qui si
      # guarda ciò che si LEGGE sullo schermo, tolto quel testo.
      it "i nomi delle fasi stanno nelle intestazioni e non dentro le righe" do
        review_ticket(title: "Da revisionare")
        sign_in(owner)

        get member_home_approvals_path

        doc = Nokogiri::HTML(response.body)
        riga = doc.at_css("[data-test='approvals-board-row']")
        riga.css(".sr-only").each(&:remove)
        # CYRA-619 — le intestazioni portano le SEI parole del modello, le stesse con cui la riga dice
        # a che punto è: fra la griglia e la colonna dello stato non resta niente da tradurre a mente.
        # CYRA-904 — one narrow column of dots: each step name lives in its dot's title.
        expect(doc.at_css("[data-test='approvals-board-head-steps']").text.strip)
          .to eq(I18n.t("member.approvals.board.columns.steps"))
        expect(doc.at_css("[data-test='approvals-board-head-plan_to_approve']")).to be_nil
        expect(riga.at_css("[data-test='approvals-board-cell-plan_to_approve'] [title]")["title"])
          .to include(I18n.t("member.tickets.automation.stage.plan_to_approve"))
        expect(riga.text).not_to include(I18n.t("member.tickets.automation.stage.plan_to_approve"))
      end
    end

    # CYRA-319 — il feed mescola le sigle di otto progetti senza dire a cosa corrispondano e senza
    # permettere di guardarne uno per volta: chi non ha creato quei progetti deve leggere tutto.
    describe "filtro per progetto (CYRA-319)" do
      let(:other_project) { create(:project, organization: org, name: "Presentforme", key: "PFRA") }

      # CYRA-899 — the groups are kinds of decision now, so the project key rides on the row, with
      # the full name on hover.
      it "shows the project key on the row, with the full name as its title" do
        review_ticket(title: "To review")
        sign_in(owner)

        get member_home_approvals_path

        chip = Nokogiri::HTML(response.body).at_css("[data-test='approvals-board-project']")
        expect(chip.text.strip).to eq(project.key)
        expect(chip["title"]).to eq(project.name)
      end

      it "filtrando per progetto restano solo le sue richieste" do
        mine = review_ticket(title: "Il mio", project: project)
        theirs = review_ticket(title: "Dell altro", project: other_project)
        sign_in(owner)

        get member_home_approvals_path(project: project.key)

        expect(response.body).to include(mine.code)
        expect(response.body).not_to include(theirs.code)
      end

      it "col filtro acceso il totale conta solo le richieste di quel progetto" do
        review_ticket(title: "Il mio", project: project)
        review_ticket(title: "Dell altro", project: other_project)
        sign_in(owner)

        get member_home_approvals_path(project: project.key)

        rows = Nokogiri::HTML(response.body).css("[data-test='approvals-board-row']")
        expect(rows.size).to eq(1)
      end

      # CYRA-651 — i progetti in coda stanno in un menu a tendina, non più in una fila di chip.
      it "mostra un menu a tendina coi progetti presenti in coda" do
        review_ticket(title: "Il mio", project: project)
        review_ticket(title: "Dell altro", project: other_project)
        sign_in(owner)

        get member_home_approvals_path

        select = Nokogiri::HTML(response.body).at_css("select[data-test='approvals-filter-project']")
        expect(select).to be_present
        expect(select.css("option").map { |option| option["value"] })
          .to include(project.key, other_project.key)
      end

      # CYRA-651 — col filtro acceso la coda è già ristretta a quel progetto, quindi in elenco ne
      # resta uno solo: se il menu sparisse, il campo uscirebbe dal form e la prima scelta fatta
      # altrove (stato, agente) allargherebbe la coda senza dirlo.
      it "il menu dei progetti resta anche quando ne è rimasto uno solo, perché è il filtro acceso" do
        review_ticket(title: "Il mio", project: project)
        review_ticket(title: "Dell altro", project: other_project)
        sign_in(owner)

        get member_home_approvals_path(project: project.key)

        select = Nokogiri::HTML(response.body).at_css("select[data-test='approvals-filter-project']")
        expect(select).to be_present
        expect(select["name"]).to eq("project")
      end

      it "il filtro resta nell indirizzo e resta scelto nel menu, così il link si condivide" do
        review_ticket(title: "Il mio", project: project)
        review_ticket(title: "Dell altro", project: other_project)
        sign_in(owner)

        get member_home_approvals_path(project: project.key)

        select = Nokogiri::HTML(response.body).at_css("select[data-test='approvals-filter-project']")
        expect(select.at_css("option[selected]")["value"]).to eq(project.key)
      end

      it "una sigla inventata vale come nessun filtro, non come coda vuota" do
        ticket = review_ticket(title: "Il mio", project: project)
        sign_in(owner)

        get member_home_approvals_path(project: "ZZZZ")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(ticket.code)
      end

      # CYRA-790 — con la coda più lunga di quanto la pagina ne renda, il progetto che occupava il
      # taglio faceva sparire gli altri dal menu e il loro filtro veniva ignorato: si riapriva la
      # coda intera proprio sul lavoro che restava nascosto.
      context "quando la coda supera quanto la pagina ne rende" do
        before { stub_const("Member::Home::ApprovalsController::BOARD_LIMIT", 1) }

        it "il progetto oltre il taglio resta nel menu" do
          # Fixture bulk nel setup: la numerazione dei ticket prende un lock per progetto, non è un
          # N+1 di produzione.
          allow_n_plus_one do
            2.times { |i| review_ticket(title: "Il mio #{i}", project: project) }
            review_ticket(title: "Dell altro", project: other_project)
          end
          sign_in(owner)

          get member_home_approvals_path

          select = Nokogiri::HTML(response.body).at_css("select[data-test='approvals-filter-project']")
          expect(select.css("option").map { |option| option["value"] })
            .to include(project.key, other_project.key)
        end

        it "filtrando per quel progetto si vedono le sue richieste, non la coda intera" do
          atteso = allow_n_plus_one do
            2.times { |i| review_ticket(title: "Il mio #{i}", project: project) }
            review_ticket(title: "Dell altro", project: other_project)
          end
          sign_in(owner)

          get member_home_approvals_path(project: other_project.key)

          expect(response.body).to include(atteso.code)
          rows = Nokogiri::HTML(response.body).css("[data-test='approvals-board-row']")
          expect(rows.size).to eq(1)
        end
      end
    end

    it "senza niente in coda mostra lo stato vuoto" do
      sign_in(owner)

      get member_home_approvals_path

      expect(response.body).to include('data-test="approvals-empty"')
      expect(response.body).not_to include('data-test="approvals-decision"')
    end

    it "apre la card indicata dal link condiviso" do
      review_ticket(title: "Prima")
      seconda = review_ticket(title: "Seconda")
      sign_in(owner)

      get member_home_approvals_path(item: "review:#{seconda.id}")

      expect(response.body).to include(seconda.code)
      expect(response.body).to include("aria-current=\"page\"")
    end

    # CYRA-325 — non più 404: la coda si carica e il messaggio è quello generico. Anti-BOLA
    # invariato — di un ticket che non mi compete non trapela niente, nemmeno il codice, e la
    # risposta è indistinguibile da quella per una richiesta mai esistita.
    it "una card che non mi compete non rivela niente (anti-BOLA)" do
      altrove = create(:project, organization: create(:organization))
      ticket = create(:ticket, organization: altrove.organization, project: altrove)
      sign_in(owner)

      get member_home_approvals_path(item: "review:#{ticket.id}")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.approvals.settled.gone"))
      expect(response.body).not_to include(ticket.code)
      expect(response.body).not_to include(ticket.title)
    end

    # CYRA-267 — il pulsante di riaccodo sta DENTRO la card, accanto alla frase che lo annuncia: la
    # decisione più frequente su una lavorazione ferma non deve costare uno scroll fino al pannello.
    it "sulla lavorazione ferma mostra il riaccodo dentro la card" do
      workflow = stalled_workflow
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-requeue"')
      expect(response.body).to include(I18n.t("member.approvals.no_plan"))
    end

    # Bocciatura sul planner: la coda lo ripropone da sé, quindi il riaccodo non compare — e il testo
    # non racconta di una lavorazione ferma che in realtà sta già riprovando. La riga non è più in
    # coda (CYRA-317): si apre la sua scheda, dove il testo resta quello.
    it "su una bocciatura che riparte da sola non mostra il riaccodo" do
      workflow = retrying_workflow
      sign_in(owner)

      get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id)

      expect(response.body).not_to include('data-test="approvals-requeue"')
      expect(response.body).to include(I18n.t("member.approvals.no_plan_retrying"))
    end

    # La guardia N+1 (Prosopite) è attiva su tutti i request spec e solleva da sé: qui serve solo
    # che la plancia abbia PIÙ righe di una, altrimenti un per-riga non si vedrebbe. Con la matrice
    # ogni riga ha cinque celle da riempire: chiedere le fasi riga per riga sarebbe il modo più
    # naturale di scriverlo, e il più veloce per mettere in ginocchio la pagina.
    it "carica una plancia con più righe senza query per riga" do
      allow_n_plus_one do
        3.times do |i|
          ticket = create(:ticket, organization: org, project:, title: "Ticket #{i}")
          workflow = create(:agent_workflow, ticket:, triage_requested_at: 3.hours.ago,
                                             triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago,
                                             planned_at: 1.hour.ago)
          create(:agent_attempt, workflow:, organization: org, phase: "triage")
        end
      end
      sign_in(owner)

      get member_home_approvals_path

      expect(response.body.scan('data-test="approvals-board-row"').size).to eq(3)
    end
  end

  # CYRA-317 — ciò che riprova da solo non chiede niente a nessuno: fuori dalla coda e dal totale, in
  # un elenco separato che si apre solo se lo si vuole guardare. Chiuderlo a mano resta possibile da
  # lì, altrimenti una lavorazione impiantata andrebbe cercata altrove.
  # CYRA-630 — l'elenco di ciò che va avanti da solo. Era «ciò che riprova da solo» (CYRA-317) e
  # conteneva le sole lavorazioni respinte che ripartivano; adesso comprende tutto ciò che è in volo
  # e non aspetta nessuno — lavoro in corso e lavorazioni mai avviate — ed è quello che diceva la
  # pagina «Lavorazioni», che non esiste più. Chiudere a mano una lavorazione impiantata resta
  # possibile da lì: è l'unica cosa che una persona può ancora volerci fare.
  describe "elenco di ciò che va avanti da solo" do
    def in_flight_path(**extra) = member_home_approvals_path(view: "in_flight", **extra)

    it "non lo mette in coda e non lo conta nel totale" do
      workflow = retrying_workflow
      sign_in(owner)

      get member_home_approvals_path

      expect(response.body).not_to include(workflow.ticket.code)
      expect(response.body).to include('data-test="approvals-empty"')
    end

    it "dalla coda si arriva all'elenco, che dice quante sono" do
      retrying_workflow
      sign_in(owner)

      get member_home_approvals_path

      link = Nokogiri::HTML(response.body).at_css("[data-test='approvals-in-flight-link']")
      expect(link).to be_present
      expect(link["href"]).to eq(in_flight_path)
      expect(link.text).to include("1")
    end

    # Il numero sta accanto al primo anche quando la coda delle decisioni ha righe sue: è quello che
    # la voce «Lavorazioni» diceva dal menu, e senza di lui l'elenco non lo troverebbe più nessuno.
    it "il secondo numero sta accanto al primo, e i due non contano la stessa riga" do
      retrying_workflow
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      # CYRA-904 — the board carries no count pills: the number rides on the link to the other list.
      pagina = Nokogiri::HTML(response.body)
      expect(pagina.at_css("[data-test='approvals-count-total']")).to be_nil
      expect(pagina.at_css("[data-test='approvals-in-flight-link']").text).to include("(1)")
    end

    it "senza niente che vada avanti da solo il rimando non compare" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      expect(response.body).not_to include('data-test="approvals-in-flight-link"')
    end

    # Il perimetro nuovo: non solo chi riprova, anche il lavoro che un agente sta facendo adesso —
    # che prima si vedeva solo dalla pagina «Lavorazioni».
    it "elenca ciò che riprova E il lavoro in corso, che prima stava su un'altra pagina" do
      retry_later = retrying_workflow
      in_corso = create(:ticket, organization: org, project:, title: "La sta facendo un agente")
      create(:agent_workflow, ticket: in_corso, triage_requested_at: 2.hours.ago, triage_started_at: 1.hour.ago)
      sign_in(owner)

      get in_flight_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(retry_later.ticket.code)
      expect(response.body).to include(in_corso.code)
      expect(response.body).to include(I18n.t("member.approvals.in_flight.title"))
      expect(response.body).to include('data-test="approvals-in-flight-row"')
    end

    # Nessuna riga dell'elenco chiede una decisione: chi aspetta una persona sta di là.
    it "non contiene niente che aspetti una persona" do
      review_ticket
      da_approvare = create(:ticket, organization: org, project:, title: "Piano da approvare")
      create(:agent_workflow, ticket: da_approvare, triage_requested_at: 3.hours.ago,
                              triage_started_at: 3.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)
      retrying_workflow
      sign_in(owner)

      get in_flight_path

      expect(response.body).not_to include(da_approvare.code)
    end

    it "da una riga si arriva alla scheda, dove resta il solo pulsante per chiuderla" do
      workflow = retrying_workflow
      sign_in(owner)

      get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id, view: "in_flight")

      expect(response.body).to include('data-test="approvals-reject"')
      expect(response.body).to include(I18n.t("member.approvals.actions.reject.review_blocked"))
      expect(response.body).not_to include('data-test="approvals-approve"')
    end

    it "da lì si torna alla coda delle decisioni" do
      retrying_workflow
      sign_in(owner)

      get in_flight_path

      link = Nokogiri::HTML(response.body).at_css("[data-test='approvals-back-queue']")
      expect(link["href"]).to eq(member_home_approvals_path)
    end

    # CYRA-665 — per chi non risponde di nessun progetto quell'elenco non esiste: 404 e mai 403,
    # come per una card che non compete. Confrontare le due risposte direbbe cosa sta girando
    # altrove.
    it "risponde 404 a chi non è responsabile di nessun progetto" do
      estraneo = create(:account)
      create(:membership, account: estraneo, organization: org, role: :member)
      create(:project_membership, account: estraneo, project:)
      sign_in(estraneo)

      get in_flight_path

      expect(response).to have_http_status(:not_found)
    end

    it "a chi non ne risponde non offre nemmeno il link dalla coda" do
      estraneo = create(:account)
      create(:membership, account: estraneo, organization: org, role: :member)
      create(:project_membership, account: estraneo, project:)
      review_ticket(reviewer: estraneo)
      sign_in(estraneo)

      get member_home_approvals_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-test="approvals-in-flight-link"')
      # Nemmeno la pillola del conteggio: renderla senza numero lascerebbe un'etichetta vuota.
      expect(response.body).not_to include('data-test="approvals-count-in-flight-total"')
      expect(response.body).to include('data-test="approvals-board"')
    end

    it "con l'elenco vuoto lo dice, invece di annunciare che non c'è più niente da decidere" do
      project # CYRA-665 — l'elenco esiste per chi risponde di almeno un progetto
      sign_in(owner)

      get in_flight_path

      expect(response.body).to include(I18n.t("member.approvals.in_flight.empty"))
      expect(response.body).not_to include(I18n.t("member.approvals.empty"))
    end

    it "chiudere una lavorazione da lì riporta all'elenco, non nella coda" do
      workflow = retrying_workflow
      sign_in(owner)

      post member_home_approvals_decision_path(view: "in_flight"),
           params: { item: "agent_plan:#{workflow.id}", decision: "reject", text: "Non serve più" }

      expect(response).to redirect_to(in_flight_path)
      expect(workflow.reload.cancelled_at).to be_present
    end

    # I link vecchi arrivano ancora: `?state=retrying` era l'indirizzo di prima, ed è dentro al
    # perimetro nuovo. Un 404 su una pagina messa nei preferiti sarebbe il modo peggiore di dirlo.
    it "l'indirizzo vecchio rimanda al nuovo" do
      sign_in(owner)

      get member_home_approvals_path(state: "retrying")

      expect(response).to redirect_to(in_flight_path)
    end
  end

  # CYRA-317 — chi apre una lavorazione respinta deve leggere cosa è stato tentato e cosa ha detto la
  # revisione: prima c'erano una frase e mezzo schermo bianco, e si chiudeva alla cieca.
  describe "dettaglio di una lavorazione respinta" do
    it "mostra il tentativo respinto e la motivazione della revisione" do
      workflow = stalled_workflow(review: "Il triage non copre il caso di rete assente")
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-detail-attempt"')
      expect(response.body).to include("Il triage non copre il caso di rete assente")
      expect(response.body).to include(I18n.t("member.approvals.attempt.title"))
    end

    it "lo mostra anche su una lavorazione che riprova da sola" do
      workflow = retrying_workflow(review: "Il piano non copre lo scenario di rollback")
      sign_in(owner)

      get member_home_approvals_item_path(kind: "agent_plan", id: workflow.id, view: "in_flight")

      expect(response.body).to include('data-test="approvals-detail-attempt"')
      expect(response.body).to include("Il piano non copre lo scenario di rollback")
    end

    it "senza motivazione lo dice, invece di lasciare il posto vuoto" do
      workflow = stalled_workflow
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-detail-attempt"')
      expect(response.body).to include(I18n.t("member.approvals.attempt.no_review"))
    end
  end

  # CYRA-557 — la scheda mostrava descrizione, analisi tecnica e criteri di accettazione, cioè tutto
  # ciò che era stato scritto prima che il lavoro cominciasse, e poi offriva Approva e Respingi. Cosa
  # fosse stato consegnato non compariva da nessuna parte: si approvava sulla fiducia.
  describe "il resoconto del lavoro nella scheda" do
    it "chi deve decidere legge il resoconto senza uscire dalla coda" do
      ticket = review_ticket(title: "Da revisionare")
      create(:ticket_report, ticket:, organization: org, body: "Ho corretto il salvataggio e aggiunto i test.")
      sign_in(owner)

      get member_home_approvals_path(item: "review:#{ticket.id}")

      expect(response.body).to include('data-test="approvals-detail-report"')
      expect(response.body).to include("Ho corretto il salvataggio e aggiunto i test.")
      expect(response.body).to include(I18n.t("member.approvals.delivered.title"))
    end

    it "senza resoconto lo dichiara, invece di lasciare il posto vuoto" do
      ticket = review_ticket(title: "Da revisionare")
      sign_in(owner)

      get member_home_approvals_path(item: "review:#{ticket.id}")

      expect(response.body).to include('data-test="approvals-detail-report-none"')
      expect(response.body).to include(I18n.t("member.approvals.delivered.none"))
    end

    it "lo mostra anche sul lavoro consegnato dall'automa" do
      ticket = create(:ticket, organization: org, project:, title: "Consegnato")
      create(:ticket_report, ticket:, organization: org, body: "Ho riscritto la coda di invio.")
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                                         planned_at: 1.day.ago, approved_at: 1.day.ago,
                                         autopilot_started_at: 1.day.ago, autopilot_completed_at: Time.current, candidate_verified_at: Time.current)
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_autopilot_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-detail-report"')
      expect(response.body).to include("Ho riscritto la coda di invio.")
    end

    # Su un PIANO il lavoro non è ancora cominciato: il blocco del consegnato non c'entra e non deve
    # comparire, altrimenti dichiarerebbe "nessun resoconto" su qualcosa che non ne può avere uno.
    it "sul piano da approvare non compare nessun blocco del consegnato" do
      ticket = create(:ticket, organization: org, project:, title: "Col piano pronto")
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                                         planned_at: Time.current)
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).not_to include('data-test="approvals-detail-report"')
    end
  end

  # CYRA-610 — prima di premere «approva» si legge in chiaro cosa quel «sì» fissa: su quale archivio
  # il lavoro potrà nascere, e qual è la prova che dirà «fatto». Prima l'approvazione non fissava
  # niente: l'archivio veniva riletto a ogni presa in carico e la prova la sceglieva chi esegue, alla
  # fine, quando era tardi per discuterne.
  describe "cosa fissa questa approvazione" do
    def piano_da_approvare(**attributes)
      ticket = create(:ticket, organization: org, project:, **attributes)
      create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                              planned_at: Time.current)
    end

    it "mostra su cosa nascerà il lavoro e come si proverà che è finito" do
      create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails",
                                 default_branch: "main", release_probe: :merge)
      workflow = piano_da_approvare(title: "Col piano pronto")
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).to include("bussolabs/closeyourit-rails")
      expect(response.body).to include(I18n.t("member.approvals.board.freeze.probe_merge"))
      expect(response.body).not_to include('data-test="approvals-detail-freeze-warning"')
    end

    it "dice in rosso quale pezzo manca, senza impedire l'approvazione" do
      workflow = piano_da_approvare(title: "Senza archivio")
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-detail-freeze-warning"')
      expect(response.body).to include(I18n.t("member.approvals.board.freeze.missing_repository"))
    end

    # Due configurazioni diverse, due posti diversi in cui si sistemano: un avviso unico manderebbe
    # a cercare.
    it "distingue «non c'e' l'archivio» da «non e' stato detto come si prova»" do
      create(:github_repository, project:, release_probe: nil)
      workflow = piano_da_approvare(title: "Senza prova decisa")
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).to include(I18n.t("member.approvals.board.freeze.missing_probe"))
      expect(response.body).not_to include(I18n.t("member.approvals.board.freeze.missing_repository"))
    end

    # L'avviso sta ANCHE nell'elenco: da lì si approvano dieci piani in una volta senza aprirne
    # nessuno, e se vivesse solo nel dettaglio quell'unico gesto sarebbe l'unico fatto alla cieca.
    it "l avviso compare nella riga dell elenco, da cui si approva in blocco" do
      piano_da_approvare(title: "Senza archivio")
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_approval")

      expect(response.body).to include('data-test="approvals-board-freeze-warning"')
      expect(response.body).to include(I18n.t("member.approvals.board.freeze.missing_short"))
    end

    it "nella riga di un piano a posto non compare nessun avviso" do
      create(:github_repository, project:, release_probe: :merge)
      piano_da_approvare(title: "A posto")
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_approval")

      expect(response.body).to include('data-test="approvals-board-row"')
      expect(response.body).not_to include('data-test="approvals-board-freeze-warning"')
    end
  end

  # CYRA-290 — la riga di filtri sopra la coda: si accende uno stato alla volta e ci si lavora dentro.
  describe "filtri per stato" do
    def planned_workflow(**attributes)
      ticket = create(:ticket, organization: org, project: project, **attributes)
      create(:agent_workflow, ticket:, planned_at: Time.current)
    end

    it "acceso uno stato, nella plancia restano solo le sue righe" do
      review_ticket(title: "Da revisionare")
      workflow = planned_workflow(title: "Col piano pronto")
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_approval")

      expect(response.body.scan('data-test="approvals-board-row"').size).to eq(1)
      expect(response.body).to include(workflow.ticket.code)
      stato = Nokogiri::HTML(response.body).at_css("select[data-test='approvals-filter-state']")
      expect(stato.at_css("option[selected]")["value"]).to eq("awaiting_approval")
    end

    # Le voci a zero si nascondono, ma non quella accesa: sparirebbe da sotto le dita appena smaltisci
    # l'ultima riga di quello stato, e resteresti col filtro attivo senza il modo di spegnerlo.
    it "la voce accesa resta nel menu anche quando lo stato si è svuotato" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path(state: "secret_change")

      stato = Nokogiri::HTML(response.body).at_css("select[data-test='approvals-filter-state']")
      expect(stato.at_css("option[selected]")["value"]).to eq("secret_change")
      expect(response.body).to include('data-test="approvals-board-empty"')
      expect(response.body).not_to include('data-test="approvals-board-row"')
    end

    it "uno stato inventato vale come «Tutte»" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path(state: "piano-a-caso")

      expect(response).to have_http_status(:ok)
      expect(response.body.scan('data-test="approvals-board-row"').size).to eq(1)
    end
  end

  describe "POST decision" do
    it "accetta e apre da sola la card successiva" do
      create(:ticket_status, :done, organization: org)
      prima = review_ticket(title: "Prima")
      prima.update_column(:updated_at, 1.year.ago)
      seconda = review_ticket(title: "Seconda")
      sign_in(owner)

      post member_home_approvals_decision_path, params: { item: "review:#{prima.id}", decision: "approve" }

      expect(response).to redirect_to(member_home_approvals_path(item: "review:#{seconda.id}"))
      expect(prima.reload.status.category).to eq("done")
    end

    it "svuotata la pila redirige alla pagina senza card" do
      create(:ticket_status, :done, organization: org)
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_decision_path, params: { item: "review:#{ticket.id}", decision: "approve" }

      expect(response).to redirect_to(member_home_approvals_path)
    end

    it "senza motivo il rifiuto torna indietro con l'avviso" do
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_decision_path, params: { item: "review:#{ticket.id}", decision: "reject" }

      expect(response).to redirect_to(member_home_approvals_path)
      expect(flash[:alert]).to be_present
      expect(ticket.reload.status.review_gate?).to be(true)
    end

    it "la nota dell'accettazione diventa un commento del ticket" do
      create(:ticket_status, :done, organization: org)
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_decision_path,
           params: { item: "review:#{ticket.id}", decision: "approve", text: "Occhio al deploy" }

      expect(ticket.comments.pluck(:body)).to include("Occhio al deploy")
    end

    # CYRA-267 — il riaccodo di una lavorazione ferma, dal pulsante dentro la card: una sola pressione,
    # senza nota, senza scendere al pannello della decisione.
    it "il riaccodo rimette in coda la fase che la revisione aveva lasciato ferma" do
      workflow = stalled_workflow
      sign_in(owner)

      post member_home_approvals_decision_path,
           params: { item: "agent_plan:#{workflow.id}", decision: "approve" }

      expect(response).to redirect_to(member_home_approvals_path)
      expect(workflow.reload.ready_execution_phase).to eq("triage")
    end

    # CYRA-290 — il filtro attraversa la decisione: la successiva è dello stesso stato, non la prima
    # del mucchio. Senza questo, smaltire dieci piani di fila richiederebbe di riaccendere il filtro
    # dieci volte.
    it "col filtro acceso apre la successiva dello stesso stato e lo tiene acceso" do
      create(:ticket_status, :done, organization: org)
      recente = review_ticket(title: "Review recente")
      recente.update_column(:updated_at, 1.hour.ago)
      prima = review_ticket(title: "Prima")
      prima.update_column(:updated_at, 1.year.ago)
      seconda = review_ticket(title: "Seconda")
      seconda.update_column(:updated_at, 6.months.ago)
      sign_in(owner)

      post member_home_approvals_decision_path(state: "review"),
           params: { item: "review:#{prima.id}", decision: "approve" }

      expect(response).to redirect_to(member_home_approvals_path(item: "review:#{seconda.id}", state: "review"))
    end

    it "col filtro acceso un errore riporta alla pagina filtrata" do
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_decision_path(state: "review"),
           params: { item: "review:#{ticket.id}", decision: "reject" }

      expect(response).to redirect_to(member_home_approvals_path(state: "review"))
      expect(flash[:alert]).to be_present
    end

    # CYRA-655 — chi decide dalla home ci deve tornare, e `return_to` non deve poter diventare una
    # porta verso fuori: è confrontato con l'unico valore ammesso, non interpretato.
    describe "il ritorno in home" do
      it "riporta in home chi ha deciso da lì" do
        create(:ticket_status, :done, organization: org)
        ticket = review_ticket
        sign_in(owner)

        post member_home_approvals_decision_path(return_to: "home"),
             params: { item: "review:#{ticket.id}", decision: "approve" }

        expect(response).to redirect_to(root_path)
      end

      it "resta sulla plancia se il valore non è quello ammesso" do
        create(:ticket_status, :done, organization: org)
        prima = review_ticket(title: "Prima")
        prima.update_column(:updated_at, 1.year.ago)
        seconda = review_ticket(title: "Seconda")
        seconda.update_column(:updated_at, 6.months.ago)
        sign_in(owner)

        post member_home_approvals_decision_path(return_to: "casa"),
             params: { item: "review:#{prima.id}", decision: "approve" }

        expect(response).to redirect_to(member_home_approvals_path(item: "review:#{seconda.id}"))
      end

      it "non manda mai fuori dal sito, nemmeno con un indirizzo intero" do
        create(:ticket_status, :done, organization: org)
        ticket = review_ticket
        sign_in(owner)

        post member_home_approvals_decision_path(return_to: "https://esempio.example/rubato"),
             params: { item: "review:#{ticket.id}", decision: "approve" }

        expect(response).to redirect_to(member_home_approvals_path)
      end

      it "riporta in home anche quando la decisione non passa" do
        ticket = review_ticket
        sign_in(owner)

        post member_home_approvals_decision_path(return_to: "home"),
             params: { item: "review:#{ticket.id}", decision: "reject" }

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to be_present
      end
    end

    it "rifiuta una decisione su una card che non mi compete" do
      altrove = create(:project, organization: create(:organization))
      ticket = create(:ticket, organization: altrove.organization, project: altrove)
      sign_in(owner)

      post member_home_approvals_decision_path, params: { item: "review:#{ticket.id}", decision: "approve" }

      expect(response).to redirect_to(member_home_approvals_path)
      expect(flash[:alert]).to be_present
    end
  end

  # CYRA-284 — l'accettazione in blocco delle card spuntate nella coda.
  describe "POST bulk" do
    it "non autenticato → redirect al login" do
      post member_home_approvals_bulk_path, params: { keys: [] }

      expect(response).to redirect_to(login_path)
    end

    it "accetta tutte le card selezionate e torna alla pila senza card aperta" do
      create(:ticket_status, :done, organization: org)
      primo = review_ticket
      secondo = review_ticket
      sign_in(owner)

      post member_home_approvals_bulk_path, params: { keys: [ "review:#{primo.id}", "review:#{secondo.id}" ] }

      expect(response).to redirect_to(member_home_approvals_path)
      expect(flash[:notice]).to be_present
      expect(primo.reload.status.category).to eq("done")
      expect(secondo.reload.status.category).to eq("done")
    end

    # CYRA-290 — filtrare e poi accettare in blocco è la coppia che rende veloce la pagina: dopo la
    # sforbiciata si torna nello stesso stato, pronti per il gruppo successivo.
    it "col filtro acceso torna alla pila filtrata" do
      create(:ticket_status, :done, organization: org)
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_bulk_path(state: "review"), params: { keys: [ "review:#{ticket.id}" ] }

      expect(response).to redirect_to(member_home_approvals_path(state: "review"))
      expect(flash[:notice]).to be_present
    end

    # Anti-BOLA: una chiave che non mi compete non è un errore, è una riga che non esiste — viene
    # scartata in silenzio e il record resta com'era.
    it "scarta le chiavi fuori dagli scope visibili" do
      create(:ticket_status, :done, organization: org)
      mia = review_ticket
      altrove = create(:project, organization: create(:organization))
      altrui = create(:ticket, organization: altrove.organization, project: altrove,
                               status: create(:ticket_status, :in_review, organization: altrove.organization))
      sign_in(owner)

      post member_home_approvals_bulk_path, params: { keys: [ "review:#{mia.id}", "review:#{altrui.id}" ] }

      expect(mia.reload.status.category).to eq("done")
      expect(altrui.reload.status.review_gate?).to be(true)
    end

    # CYRA-1048 — the selection is resolved with one read per family, not one per card. Two cards were
    # not enough to see the repetition (Rails 8.1.3 only reported it from the third card on), so these
    # use more. Only the approval of each single card may repeat its queries: see spec/support/prosopite.rb.
    [ 3, 5 ].each do |count|
      it "approves #{count} review cards without reading each one again" do
        create(:ticket_status, :done, organization: org)
        tickets = allow_n_plus_one { Array.new(count) { review_ticket } }
        sign_in(owner)

        post member_home_approvals_bulk_path, params: { keys: tickets.map { |ticket| "review:#{ticket.id}" } }

        expect(response).to redirect_to(member_home_approvals_path)
        expect(flash[:notice]).to be_present
        expect(Ticketing::Ticket.where(id: tickets).includes(:status).map { |ticket| ticket.status.category }.uniq)
          .to eq([ "done" ])
      end
    end

    it "approves 3 plans without reading each workflow again" do
      workflows = allow_n_plus_one do
        Array.new(3) do
          create(:agent_workflow, ticket: create(:ticket, organization: org, project:), planned_at: Time.current).tap do |workflow|
            attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner")
            Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Plan", scenarios: [],
                                 definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
          end
        end
      end
      sign_in(owner)

      post member_home_approvals_bulk_path, params: { keys: workflows.map { |workflow| "agent_plan:#{workflow.id}" } }

      expect(response).to redirect_to(member_home_approvals_path)
      expect(flash[:notice]).to be_present
      expect(Agents::Workflow.where(id: workflows).pluck(:approved_at)).to all(be_present)
    end

    it "senza nessuna selezione avvisa e non fa nulla" do
      ticket = review_ticket
      sign_in(owner)

      post member_home_approvals_bulk_path, params: { keys: [] }

      expect(response).to redirect_to(member_home_approvals_path)
      expect(flash[:alert]).to be_present
      expect(ticket.reload.status.review_gate?).to be(true)
    end

    # CYRA-289 — in produzione una card che sollevava faceva finire l'intera richiesta in 500, con le
    # precedenti già accettate e nessun modo di sapere quali. Il resoconto deve arrivare comunque.
    it "una card che solleva non manda la pagina in errore: le altre passano e l'esito si legge" do
      create(:ticket_status, :done, organization: org)
      buono = review_ticket
      rotto = review_ticket
      allow(Home::Approvals::Decide).to receive(:call).and_call_original
      allow(Home::Approvals::Decide).to receive(:call).with(hash_including(key: "review:#{rotto.id}"))
                                                     .and_raise(ActiveRecord::StatementTimeout, "database is locked")
      sign_in(owner)

      post member_home_approvals_bulk_path, params: { keys: [ "review:#{rotto.id}", "review:#{buono.id}" ] }

      expect(response).to redirect_to(member_home_approvals_path)
      expect(flash[:alert]).to be_present
      expect(flash[:alert]).not_to include("database is locked")
      expect(buono.reload.status.category).to eq("done")
      expect(rotto.reload.status.review_gate?).to be(true)
    end
  end
  # CYRA-325 — il link a una richiesta è condivisibile: se nel frattempo è stata decisa, prima
  # compariva il 404 di sistema (inglese, senza menu) al posto della coda.
  describe "link a una richiesta che non è più in coda" do
    it "carica comunque la coda e dice che è già stata decisa, da chi e quando" do
      deciso = create(:ticket, organization: org, project:)
      workflow = create(:agent_workflow, ticket: deciso, planned_at: 2.hours.ago,
                                         approved_at: 1.hour.ago, approved_by: owner)
      in_coda = create(:ticket, organization: org, project:)
      create(:agent_workflow, ticket: in_coda, planned_at: 30.minutes.ago)
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{workflow.id}")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="approvals-settled"')
      # Il nome si confronta sul TESTO reso, non sull'HTML: un apostrofo nel nome (Faker ne genera)
      # nel sorgente è `&#39;`, e l'asserzione sul corpo grezzo fallirebbe a caso.
      expect(Nokogiri::HTML(response.body).text).to include(owner.name)
      expect(response.body).to include(deciso.code)
      # CYRA-592 — la plancia è lì sotto, e mostra ciò che resta: si torna a guardare l'insieme,
      # invece di restare su una scheda che non c'è più.
      expect(response.body).to include('data-test="approvals-board"')
      expect(response.body).to include(in_coda.code)
    end

    it "una richiesta che non esiste non svuota la pagina" do
      create(:agent_workflow, ticket: create(:ticket, organization: org, project:),
                              planned_at: 1.hour.ago)
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{SecureRandom.uuid}")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="approvals-settled"')
      expect(response.body).to include(I18n.t("member.approvals.settled.gone"))
    end

    # CYRA-998 — a passing notice, so it is a toast like the others, not a bar over the page.
    it "shows the settled notice as a toast in the bottom-right stack" do
      sign_in(owner)

      get member_home_approvals_path(item: "agent_plan:#{SecureRandom.uuid}")

      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-test='flash-container'] [data-test='approvals-settled']")).to be_present
      expect(page.css("[data-test='approvals-settled']").size).to eq(1)
    end

    it "una chiave malformata non manda in errore" do
      sign_in(owner)

      get member_home_approvals_path(item: "non-una-chiave")

      expect(response).to have_http_status(:ok)
    end
  end
  # ── CYRA-616 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Dando il secondo sì — quello sul lavoro consegnato — davanti c'erano il piano e il racconto di chi
  # aveva lavorato. Parole. Il codice non si vedeva: per vederlo bisognava uscire dalla pagina, aprire
  # il ticket e guardare l'elenco delle proposte, ordinate dalla più recente e senza dire da nessuna
  # parte quale versione esatta fosse stata controllata.
  describe "su cosa stai dicendo di sì" do
    def consegna_verificata(stato: :verified_passing, verbale: true)
      ticket = create(:ticket, organization: org, project:, title: "Consegnato")
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triage_started_at: 2.days.ago,
                                         triaged_at: 1.day.ago, planned_at: 1.day.ago, approved_at: 1.day.ago,
                                         autopilot_started_at: 1.day.ago, autopilot_completed_at: Time.current,
                                         candidate_verified_at: Time.current)
      if verbale
        candidato = create(:agent_delivery_candidate, stato, workflow:, organization: org,
                                                      repository_full_name: "bussolabs/closeyourit-rails",
                                                      number: 12, head_sha: "e" * 40, base_ref: "main")
        workflow.update!(review_candidate: candidato)
      end
      workflow
    end

    it "mostra archivio, numero, versione esatta e ramo di destinazione" do
      workflow = consegna_verificata
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_autopilot_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-detail-candidate"')
      expect(response.body).to include("bussolabs/closeyourit-rails")
      expect(response.body).to include("#12")
      # Per intero, non abbreviata, e come TESTO che si legge: dentro l'indirizzo del link la sigla
      # intera c'è comunque, quindi cercarla lì non proverebbe che chi guarda la vede.
      expect(response.body).to match(/>#{'e' * 40}</)
      expect(response.body).to include(I18n.t("member.approvals.candidate.onto", base: "main"))
    end

    # La riga porta al codice esatto, non alla proposta e basta: è quello che si sta approvando.
    it "il codice si apre cliccandolo" do
      workflow = consegna_verificata
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_autopilot_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).to include("https://github.com/bussolabs/closeyourit-rails/pull/12/commits/#{'e' * 40}")
    end

    # Se approvi senza rete di sicurezza, lo fai sapendolo.
    it "senza controlli automatici lo dice, in rosso" do
      workflow = consegna_verificata(stato: :verified_none_configured)
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_autopilot_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).to include(I18n.t("member.approvals.candidate.none_configured"))
      expect(response.body).to include("text-red-700")
    end

    # Non tace e non mette al suo posto un dato plausibile e sbagliato.
    it "se il verbale manca, lo dichiara" do
      workflow = consegna_verificata(verbale: false)
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_autopilot_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).to include('data-test="approvals-detail-candidate-none"')
      expect(response.body).not_to include('data-test="approvals-detail-candidate-sha"')
    end

    # Sul piano la riga non c'è affatto, e non c'è nemmeno vuota: lì il codice non è ancora stato
    # scritto, e un riquadro vuoto farebbe credere che qualcosa sia già stato controllato.
    it "sul piano da approvare la riga non compare affatto" do
      ticket = create(:ticket, organization: org, project:, title: "Col piano pronto")
      workflow = create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triaged_at: 1.day.ago,
                                         planned_at: Time.current)
      # Il verbale ESISTE (una lavorazione precedente lo aveva lasciato): a tenerlo fuori dalla
      # scheda dev'essere la regola, non il caso. Senza questa riga la prova passerebbe anche se la
      # regola sparisse, perché non ci sarebbe niente da mostrare.
      workflow.update!(review_candidate: create(:agent_delivery_candidate, :verified_passing, workflow:,
                                                                          organization: org))
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_approval", item: "agent_plan:#{workflow.id}")

      expect(response.body).not_to include('data-test="approvals-detail-candidate"')
      expect(response.body).not_to include('data-test="approvals-detail-candidate-none"')
    end

    # Aprire la scheda non chiede niente a GitHub: quello che si legge è stato registrato al momento
    # del controllo, e non può cambiare sotto gli occhi mentre si decide.
    it "non chiama GitHub per renderla" do
      workflow = consegna_verificata
      allow(Github::Client).to receive(:new).and_raise("nessuna chiamata a GitHub nel render")
      sign_in(owner)

      get member_home_approvals_path(state: "awaiting_autopilot_approval", item: "agent_plan:#{workflow.id}")

      expect(response).to have_http_status(:ok)
    end
  end

  # CYRA-863 — sulla plancia le revisioni senza resoconto si riconoscono e si smaltiscono in blocco.
  describe "revisioni senza resoconto sulla plancia" do
    it "porta il segno solo la revisione senza un lavoro consegnato" do
      bare = review_ticket(title: "Senza verbale")
      reported = review_ticket(title: "Con verbale")
      create(:ticket_report, ticket: reported, organization: org, body: "Fatto.")
      rejected = review_ticket(title: "Solo rifiuto")
      create(:ticket_report, ticket: rejected, organization: org, body: "Non va.", source: :review_rejection)
      sign_in(owner)

      get member_home_approvals_path

      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-test='approvals-no-report-#{bare.id}']")).to be_present
      expect(html.at_css("[data-test='approvals-no-report-#{rejected.id}']")).to be_present
      expect(html.at_css("[data-test='approvals-no-report-#{reported.id}']")).to be_nil
    end
  end

  # CYRA-899 — the board as a place to work the queue: counters per step, approve from the row,
  # a preview without leaving the page, a coloured wait, stuck rows marked, keyboard shortcuts.
  describe "working the board" do
    def planned(**attributes)
      create(:agent_workflow, ticket: create(:ticket, organization: org, project:), planned_at: Time.current,
                              **attributes)
    end

    def blocked
      workflow = create(:agent_workflow, ticket: create(:ticket, organization: org, project:),
                                         triage_requested_at: 4.hours.ago, triage_started_at: 4.hours.ago,
                                         triaged_at: 3.hours.ago, planned_at: 2.hours.ago, approved_at: 2.hours.ago,
                                         autopilot_started_at: 1.hour.ago, blocked_at: 30.minutes.ago,
                                         blocked_phase: "autopilot", blocked_kind: "attempt_limit")
      create(:agent_attempt, workflow:, organization: org, phase: "autopilot", status: :review_failed)
      workflow
    end

    def doc = Nokogiri::HTML(response.body)

    # CYRA-998 — a rewritten plan says which version is waiting, without opening it.
    it "shows the plan version on the row, one query for the whole board" do
      allow_n_plus_one do
        rewritten = planned
        fresh = planned
        [ rewritten, rewritten, rewritten, fresh ].each do |workflow|
          attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner")
          Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Plan", scenarios: [],
                               definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
        end
      end
      sign_in(owner)

      get member_home_approvals_path

      versions = doc.css("[data-test='approvals-board-plan-version']").map { |node| node.text.strip }
      expect(versions).to contain_exactly("v3", "v1")
    end

    # CYRA-998 — version and wait are columns of their own, and both sort the rows inside each group.
    describe "version and wait columns" do
      def plan_rows(versions)
        allow_n_plus_one do
          versions.map do |count|
            planned.tap do |workflow|
              count.times do
                attempt = create(:agent_attempt, workflow:, organization: org, phase: "planner")
                Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Plan", scenarios: [],
                                     definition_of_done: [], notes: [], ticket_snapshot_digest: "snapshot")
              end
            end
          end
        end
      end

      def row_versions = doc.css("[data-test='approvals-board-plan-version']").map { |node| node.text.strip }

      it "has sortable version and wait headers" do
        plan_rows([ 1 ])
        sign_in(owner)

        get member_home_approvals_path

        expect(doc.at_css("th [href*='sort=-version']")).to be_present
        expect(doc.at_css("th [href*='sort=-wait']")).to be_present
      end

      it "sorts by wait, longest first" do
        older, newer = plan_rows([ 1, 2 ])
        older.update_column(:updated_at, 3.days.ago)
        newer.update_column(:updated_at, 1.hour.ago)
        sign_in(owner)

        get member_home_approvals_path(sort: "-wait")

        expect(row_versions).to eq(%w[v1 v2])
      end

      it "sorts by version, highest first when asked" do
        plan_rows([ 1, 3, 2 ])
        sign_in(owner)

        get member_home_approvals_path(sort: "-version")
        expect(row_versions).to eq(%w[v3 v2 v1])

        get member_home_approvals_path(sort: "version")
        expect(row_versions).to eq(%w[v1 v2 v3])
      end

      it "ignores an unknown sort key" do
        plan_rows([ 1, 3 ])
        sign_in(owner)

        get member_home_approvals_path(sort: "drop table")

        expect(response).to have_http_status(:ok)
        expect(row_versions).to eq(%w[v1 v3])
      end
    end

    it "counts the rows on each step and links each counter to the filtered board" do
      allow_n_plus_one { 2.times { planned } }
      sign_in(owner)

      get member_home_approvals_path

      counter = doc.at_css("[data-test='approvals-phase-counter-plan_to_approve']")
      expect(counter.text).to include("2")
      expect(counter["href"]).to eq(member_home_approvals_path(phase: "plan_to_approve"))
      expect(doc.css("[data-test^='approvals-phase-counter-']").size)
        .to eq(Agents::Workflows::PhaseResolver::STEPS.size)
    end

    it "with a step chosen keeps only its rows, and its counter links back to everything" do
      allow_n_plus_one do
        planned
        blocked
      end
      sign_in(owner)

      get member_home_approvals_path(phase: "in_progress")

      expect(doc.css("[data-test='approvals-board-row']").size).to eq(1)
      counter = doc.at_css("[data-test='approvals-phase-counter-in_progress']")
      expect(counter["aria-current"]).to eq("true")
      expect(counter["href"]).to eq(member_home_approvals_path)
    end

    it "offers Approve on the row only where approving in bulk is allowed" do
      ticket = review_ticket(title: "To review")
      sign_in(owner)

      get member_home_approvals_path

      button = doc.at_css("[data-test='approvals-row-approve']")
      expect(button["name"]).to eq("keys[]")
      expect(button["value"]).to eq("review:#{ticket.id}")
      form = doc.at_css("form##{button['form']}")
      expect(form["action"]).to eq(member_home_approvals_bulk_path)
    end

    it "approving from the row approves that row alone" do
      create(:ticket_status, :done, organization: org)
      chosen = review_ticket
      other = review_ticket
      sign_in(owner)

      post member_home_approvals_bulk_path, params: { keys: [ "review:#{chosen.id}" ] }

      expect(chosen.reload.status.category).to eq("done")
      expect(other.reload.status.category).not_to eq("done")
    end

    it "approving keeps the chosen step, on the form and on the way back" do
      create(:ticket_status, :done, organization: org)
      ticket = review_ticket
      sign_in(owner)

      get member_home_approvals_path(phase: "to_review")

      expect(doc.at_css("form#approvals-approve-one")["action"]).to include("phase=to_review")

      post member_home_approvals_bulk_path(phase: "to_review"), params: { keys: [ "review:#{ticket.id}" ] }

      expect(response).to redirect_to(member_home_approvals_path(phase: "to_review"))
    end

    it "changing the other filters keeps the chosen step" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path(phase: "to_review")

      filters = doc.at_css("[data-test='approvals-filters']")
      form = filters.name == "form" ? filters : filters.at_css("form") || filters.ancestors("form").first
      expect(form.at_css("input[type='hidden'][name='phase']")["value"]).to eq("to_review")
    end

    it "a made-up step is dropped on the way back" do
      sign_in(owner)

      post member_home_approvals_bulk_path(phase: "nonsense"), params: { keys: [] }

      expect(response).to redirect_to(member_home_approvals_path)
    end

    it "has no Approve on a row that cannot be approved in bulk" do
      workflow = create(:agent_workflow, ticket: create(:ticket, organization: org, project:, reviewer: owner),
                                         triage_requested_at: 2.hours.ago, triage_started_at: 2.hours.ago,
                                         triaged_at: 1.hour.ago)
      attempt = create(:agent_attempt, workflow:, organization: org, phase: "triage")
      create(:agent_clarification, workflow:, attempt:, questions: [ "Which environment?" ])
      sign_in(owner)

      get member_home_approvals_path

      expect(doc.at_css("[data-test='approvals-board-row']")).to be_present
      expect(doc.at_css("[data-test='approvals-row-approve']")).to be_nil
    end

    it "every row carries a hidden preview that loads lazily" do
      ticket = review_ticket(title: "To review")
      sign_in(owner)

      get member_home_approvals_path

      frame = doc.at_css("[data-test='approvals-row-preview'] turbo-frame")
      expect(frame["src"]).to eq(member_home_approvals_item_preview_path(kind: "review", id: ticket.id))
      expect(frame["loading"]).to eq("lazy")
      expect(doc.at_css("[data-test='approvals-row-preview']")["hidden"]).not_to be_nil
    end

    it "the preview shows the request inside its frame" do
      ticket = review_ticket(title: "Rework the invoices")
      sign_in(owner)

      get member_home_approvals_item_preview_path(kind: "review", id: ticket.id)

      expect(response).to have_http_status(:ok)
      frame = doc.at_css("turbo-frame#approvals-preview-review-#{ticket.id}")
      expect(frame.text).to include("Rework the invoices")
    end

    it "the preview of a request out of my scope does not exist" do
      elsewhere = create(:project, organization: create(:organization))
      foreign = create(:ticket, organization: elsewhere.organization, project: elsewhere,
                                status: create(:ticket_status, :in_review, organization: elsewhere.organization))
      sign_in(owner)

      get member_home_approvals_item_preview_path(kind: "review", id: foreign.id)

      expect(response).to have_http_status(:not_found)
    end

    it "paints the wait red after two days" do
      ticket = review_ticket
      ticket.update_column(:updated_at, 3.days.ago)
      sign_in(owner)

      get member_home_approvals_path

      expect(doc.at_css("[data-test='approvals-board-wait']")["class"]).to include("text-red-600")
    end

    it "marks the rows stopped on a step" do
      allow_n_plus_one do
        planned
        blocked
      end
      sign_in(owner)

      get member_home_approvals_path

      stuck = doc.css("[data-test='approvals-board-row']").map { |row| row["data-stuck"] }
      expect(stuck).to contain_exactly("true", "false")
    end

    # CYRA-1057 — a blocked row restarts from the board, without opening its ticket.
    it "offers retry only on blocked rows, posting to the ticket unblock" do
      stopped = nil
      allow_n_plus_one do
        planned
        stopped = blocked
      end
      sign_in(owner)

      get member_home_approvals_path

      retries = doc.css("[data-test='approvals-row-retry']")
      expect(retries.size).to eq(1)
      # The row sits inside the bulk form: without its own `form` the button would approve the ticked rows.
      expect(retries.first["form"]).to eq("approvals-row-actions")
      expect(doc.css("[data-test='approvals-board-row'] form")).to be_empty
      expect(doc.at_css("form#approvals-row-actions")).to be_present
      expect(retries.first["formaction"])
        .to eq(member_ticket_automation_unblock_path(stopped.ticket, return_to: "approvals",
                                                     row: "agent_plan:#{stopped.id}"))
    end

    # CYRA-1059 — row actions run without reloading the board: the answer removes the row by its id.
    describe "row actions without reloading" do
      let(:stream) { { "Accept" => "text/vnd.turbo-stream.html, text/html" } }

      it "gives every row and its preview an id the answer can target" do
        ticket = review_ticket
        sign_in(owner)

        get member_home_approvals_path

        expect(doc.at_css("tr[data-test='approvals-board-row']")["id"]).to eq("approvals-row-review-#{ticket.id}")
        expect(doc.at_css("tr[data-test='approvals-row-preview']")["id"]).to eq("approvals-row-review-#{ticket.id}-preview")
        expect(doc.at_css("[data-controller~='approvals-row-actions']")).to be_present
      end

      it "hands the script both wordings of a group's count, so it can lower it after a row goes" do
        review_ticket
        sign_in(owner)

        get member_home_approvals_path

        board = doc.at_css("[data-controller~='approvals-row-actions']")
        labels = JSON.parse(board["data-approvals-row-actions-count-labels-value"])
        expect(labels).to eq("one" => "1 row", "other" => "%{count} rows")
        expect(doc.at_css("tr[data-row-group-header] span[data-row-group-count]")).to be_present
      end

      it "approving from the row answers with a stream that removes the row and says so" do
        create(:ticket_status, :done, organization: org)
        ticket = review_ticket
        sign_in(owner)

        post member_home_approvals_bulk_path, params: { keys: [ "review:#{ticket.id}" ], from_row: "1" }, headers: stream

        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include('action="remove" target="approvals-row-review-%s"' % ticket.id)
        expect(response.body).to include('action="remove" target="approvals-row-review-%s-preview"' % ticket.id)
        expect(response.body).to include('action="replace" target="flash-container"')
        expect(response.body).to include(I18n.t("member.approvals.bulk.done", count: 1))
        expect(ticket.reload.status.category).to eq("done")
      end

      it "keeps the row and shows why when the approval is refused" do
        sign_in(owner)

        post member_home_approvals_bulk_path, params: { keys: [], from_row: "1" }, headers: stream

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to include('action="remove"')
        expect(response.body).to include('action="replace" target="flash-container"')
      end

      it "puts the header counters in a frame of their own that reloads alone" do
        review_ticket
        sign_in(owner)

        get member_home_approvals_path

        frame = doc.at_css("turbo-frame#approvals-counts")
        expect(frame["target"]).to eq("_top")
        expect(frame.at_css("[data-test='approvals-phase-counter-to_review']")).to be_present

        get member_home_approvals_path, headers: { "Turbo-Frame" => "approvals-counts" }

        expect(response.body).to include('id="approvals-counts"')
        expect(response.body).not_to include("<body")
      end
    end

    it "wires the keyboard shortcuts and lists them in the shortcut help" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      board = doc.at_css("[data-controller~='approvals-board-keys']")
      expect(board).to be_present
      keys = JSON.parse(board["data-keyboard-doc"]).map { |entry| entry["keys"] }
      expect(keys).to include("j", "k", "Enter", "a", "x")
    end
  end

  # CYRA-904 — a lighter board: the decision stays on screen and nothing is said twice.
  describe "lighter board" do
    def doc = Nokogiri::HTML(response.body)

    # CYRA-998 — the wait moved back to a column of its own, so the rows can be sorted by it.
    it "puts the wait in a sortable column of its own, not next to the ticket title" do
      review_ticket(title: "Waiting review")
      sign_in(owner)

      get member_home_approvals_path

      expect(doc.at_css("th [href*='sort=-wait']")).to be_present
      expect(doc.at_css("[data-test='approvals-board-title-cell'] [data-test='approvals-board-wait']")).to be_nil
      expect(doc.at_css("[data-test='approvals-board-wait']")).to be_present
    end

    it "keeps approve and decide in a cell pinned to the right edge" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      cell = doc.at_css("[data-test='approvals-board-actions']")
      expect(cell.ancestors("table").first["class"]).to include("ui-table--sticky-last")
      expect(cell.next_element).to be_nil
      expect(cell.at_css("[data-test='approvals-board-decide']")).to be_present
    end

    it "shows the agent in the preview row, not in a board column" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      expect(doc.css("th").map { |th| th.text.strip }).not_to include(I18n.t("member.approvals.board.columns.agent"))
      expect(doc.at_css("[data-test='approvals-row-preview'] [data-test='approvals-board-agent']")).to be_present
    end

    it "offers to tick the rows without a report from the group header" do
      review_ticket(title: "Bare one")
      review_ticket(title: "Bare two")
      reported = review_ticket(title: "Reported")
      create(:ticket_report, ticket: reported, organization: org, body: "Done.")
      sign_in(owner)

      get member_home_approvals_path

      button = doc.at_css("[data-test='approvals-select-no-report']")
      expect(button.text).to include(I18n.t("member.approvals.board.select_no_report", count: 2))
      expect(doc.css("input[data-no-report='true']").size).to eq(2)
    end

    it "leaves the count pills to the other list" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      expect(doc.at_css("[data-test='approvals-counts']")).to be_nil
      expect(doc.at_css("[data-test='approvals-phase-counters']")).to be_present
    end

    # The phase counters are the counts line of the page header; the filter bar sits inside the panel.
    it "puts the phase counters in the page header and the filter bar inside the panel" do
      review_ticket
      sign_in(owner)

      get member_home_approvals_path

      board = doc.at_css("[data-test='approvals-board']")
      panel = board.at_css("[data-test='approvals-board-panel']")
      expect(panel.at_css("[data-test='approvals-filters']")).to be_present
      expect(board.at_css("[data-test='approvals-phase-counters']")).to be_nil
      expect(doc.at_css("[data-test='approvals-header'] [data-test='approvals-phase-counters']")).to be_present
    end
  end
end
