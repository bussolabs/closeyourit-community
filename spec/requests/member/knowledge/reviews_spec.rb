# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Knowledge::Reviews", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET /member/knowledge/reviews" do
    # G1 — with nothing waiting, the page says by example how a proposal gets here.
    it "with nothing waiting gives an example of how a proposal arrives" do
      sign_in(owner)
      get member_knowledge_reviews_path

      empty = Capybara.string(response.body).find("[data-test='knowledge-review-empty']")
      expect(empty.find("[data-test='empty-example']").text).to eq(I18n.t("member.knowledge.reviews.empty_example"))
    end

    it "elenca le proposte in attesa con la loro motivazione e il testo" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project,
                                                     title: "Trappola dei worktree", body: "Il database è condiviso.")
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(proposta.title)
      expect(response.body).to include(proposta.review_note)
      expect(response.body).to include("Il database è condiviso.")
    end

    # CYRA-419 — la coda attribuiva la proposta alla persona il cui accesso era stato usato: chi
    # revisionava credeva di controllare il lavoro di un collega e abbassava la guardia.
    it "dichiara che l'ha scritta un assistente e con l'accesso di chi" do
      create(:knowledge_page, :in_review, :written_by_agent, organization: org, project: project,
                                          title: "Trappola dei worktree", created_by: member)
      sign_in(owner)

      get member_knowledge_reviews_path

      riga = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-review-written-by"]').text
      expect(riga).to include(I18n.t("member.knowledge.author.agent_with_origin", origin: "kb-inbox"))
      expect(riga).to include(I18n.t("member.knowledge.author.on_behalf_of", account: member.name))
    end

    it "senza origine registrata lo dice, invece di attribuirla a una persona" do
      create(:knowledge_page, :in_review, organization: org, project: project,
                                          title: "Trappola dei worktree", created_by: member)
      sign_in(owner)

      get member_knowledge_reviews_path

      riga = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-review-written-by"]').text
      expect(riga).to include(I18n.t("member.knowledge.author.unregistered"))
      expect(riga).to include(I18n.t("member.knowledge.author.on_behalf_of", account: member.name))
    end

    # CYRA-425 — la disposizione È il messaggio: se i bottoni stanno sopra il testo, la pagina invita
    # a decidere prima di leggere. L'ordine nel markup è la garanzia che si legga per primo il testo.
    it "mette il testo da giudicare PRIMA dei bottoni che decidono" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project,
                                                     title: "Trappola dei worktree", body: "Il database è condiviso.")
      sign_in(owner)

      get member_knowledge_reviews_path

      testo = response.body.index("knowledge-review-body")
      accetta = response.body.index("knowledge-review-accept-#{proposta.id}")
      scarta = response.body.index("knowledge-review-reject-#{proposta.id}")
      expect(testo).to be < accetta
      expect(testo).to be < scarta
    end

    it "rende il markdown del testo e della parte tecnica invece di mostrare cancelletti e backtick" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Trappola dei worktree",
                                          body: "## Sintomo\n\nIl database è condiviso.",
                                          tech_spec: "Comando: `bin/rails db:prepare`")
      sign_in(owner)

      get member_knowledge_reviews_path

      html = Nokogiri::HTML(response.body)
      body = html.at_css('[data-test="knowledge-review-body"]')
      expect(body.at_css("h2").text).to eq("Sintomo")
      expect(body.text).not_to include("## ")
      expect(html.at_css('[data-test="knowledge-review-tech-spec"] code').text).to eq("bin/rails db:prepare")
    end

    it "scrive accanto a ciascun bottone la conseguenza della decisione" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Trappola dei worktree")
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.knowledge.reviews.accept_hint")))
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.knowledge.reviews.reject_hint")))
    end

    it "non mostra le pagine già pubblicate e archiviate: la coda è solo ciò che aspetta" do
      pubblicata = create(:knowledge_page, organization: org, project: project, title: "Pagina pubblicata",
                                           consolidated_at: Time.current, source_path: "global/git.md")
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response.body).not_to include(pubblicata.title)
    end

    it "elenca le accettate che non sono ancora state archiviate" do
      da_archiviare = create(:knowledge_page, organization: org, project: project, title: "Manca fra i documenti",
                                              reviewed_at: Time.current)
      archiviata = create(:knowledge_page, organization: org, project: project, title: "Già archiviata",
                                           reviewed_at: Time.current,
                                           consolidated_at: Time.current, source_path: "global/git.md")
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response.body).to include(da_archiviare.title)
      expect(response.body).not_to include(archiviata.title)
    end

    it "non elenca fra le accettate le pagine scritte a mano, mai passate dalla revisione" do
      scritta_a_mano = create(:knowledge_page, organization: org, project: project, title: "Scritta dal web")
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response.body).not_to include(scritta_a_mano.title)
    end

    it "non mostra le proposte dei progetti che non vedo" do
      altro_progetto = create(:project, organization: org)
      nascosta = create(:knowledge_page, :in_review, organization: org, project: altro_progetto, title: "Non mia")
      sign_in(member)

      get member_knowledge_reviews_path

      expect(response.body).not_to include(nascosta.title)
    end
  end

  # CYRA-560 — la coda arrivava a centosessantasette proposte in un blocco solo: quasi cinquanta
  # schermate da scorrere per decidere sulla centesima, senza pagine, senza filtri, senza ricerca.
  describe "GET /member/knowledge/reviews — coda lunga (CYRA-560)" do
    # Le proposte nascono a distanza di un'ora l'una dall'altra: l'ordine è la più recente in cima,
    # quindi "Proposta 0" apre la prima pagina e l'ultima creata chiude la coda.
    def coda_di(quante)
      Array.new(quante) do |i|
        create(:knowledge_page, :in_review, organization: org, project: project,
                                            title: "Proposta #{i}", created_at: (i + 1).hours.ago)
      end
    end

    it "divide la coda in pagine invece di stamparle tutte insieme" do
      coda_di(13)
      sign_in(owner)

      get member_knowledge_reviews_path

      righe = Nokogiri::HTML(response.body).css('[data-test="knowledge-review-row"]')
      expect(righe.size).to eq(Pagination::DEFAULT_PER)
      expect(response.body).to include("Proposta 0")
      expect(response.body).not_to include("Proposta 12")
    end

    it "la pagina successiva mostra le proposte rimaste" do
      coda_di(13)
      sign_in(owner)

      get member_knowledge_reviews_path(page: 2)

      expect(response.body).to include("Proposta 12")
      expect(response.body).not_to include("Proposta 0")
    end

    it "il conteggio in alto resta quello di tutta la coda, non della pagina" do
      coda_di(13)
      sign_in(owner)

      get member_knowledge_reviews_path

      chip = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-review-stat-waiting"]').text
      expect(chip).to include("13")
    end

    it "filtra le proposte per progetto" do
      altro_progetto = create(:project, organization: org, name: "Altro progetto")
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta del mio")
      create(:knowledge_page, :in_review, organization: org, project: altro_progetto, title: "Proposta dell'altro")
      sign_in(owner)

      get member_knowledge_reviews_path(project_id: [ project.id ])

      expect(response.body).to include("Proposta del mio")
      expect(response.body).not_to include("Proposta dell&#39;altro")
    end

    it "cerca le proposte per titolo" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Trappola dei worktree")
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Come si scrive una guida")
      sign_in(owner)

      get member_knowledge_reviews_path(q: "trappola")

      expect(response.body).to include("Trappola dei worktree")
      expect(response.body).not_to include("Come si scrive una guida")
    end

    # La coda piena non deve mai dire "non c'è niente in attesa": è la ricerca a non aver trovato.
    it "a ricerca senza corrispondenze dice quante proposte aspettano davvero" do
      coda_di(3)
      sign_in(owner)

      get member_knowledge_reviews_path(q: "niente-che-esista")

      expect(response.body).to include(ERB::Util.html_escape(I18n.t("member.knowledge.reviews.no_results_body", count: 3)))
      expect(response.body).not_to include(I18n.t("member.knowledge.reviews.empty_body"))
    end

    it "la coda davvero vuota resta il messaggio di prima" do
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response.body).to include(I18n.t("member.knowledge.reviews.empty_body"))
    end

    # Scenario 2 — dopo una decisione la pagina si aggiorna sul posto invece di ricostruirsi da capo
    # e riportare in cima (stessa scelta delle altre otto liste dell'area).
    it "chiede a Turbo di aggiornare sul posto conservando la posizione" do
      create(:knowledge_page, :in_review, organization: org, project: project)
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response.body).to include('name="turbo-refresh-method" content="morph"')
      expect(response.body).to include('name="turbo-refresh-scroll" content="preserve"')
    end
  end

  # CYRA-571 — accetta e scarta costruivano un modulo a testa PER OGNI proposta: la coda superava il
  # megabyte e si ricostruiva così a ogni decisione. Ora le decisioni puntano il modulo unico della
  # pagina, quindi il peso segue le righe che si vedono e non le azioni che offrono.
  describe "GET /member/knowledge/reviews — peso della coda (CYRA-571)" do
    def moduli(body) = body.scan("<form").size

    def coda_di(quante)
      Array.new(quante) do |i|
        create(:knowledge_page, :in_review, organization: org, project: project,
                                            title: "Proposta #{i}", created_at: (i + 1).hours.ago)
      end
    end

    it "non costruisce un modulo per ogni decisione di ogni proposta" do
      coda_di(1)
      sign_in(owner)
      get member_knowledge_reviews_path
      con_una = moduli(response.body)

      allow_n_plus_one { coda_di(9) }
      get member_knowledge_reviews_path
      con_dieci = moduli(response.body)

      expect(Nokogiri::HTML(response.body).css('[data-test="knowledge-review-row"]').size).to eq(10)
      expect(con_dieci).to eq(con_una)
    end

    it "le due decisioni puntano il modulo condiviso della pagina" do
      proposta = coda_di(1).first
      sign_in(owner)

      get member_knowledge_reviews_path

      html = Nokogiri::HTML(response.body)
      expect(html.at_css("form#row-actions")).to be_present
      accetta = html.at_css("[data-test='knowledge-review-accept-#{proposta.id}']")
      expect(accetta["form"]).to eq("row-actions")
      expect(accetta["formaction"]).to eq(approve_member_knowledge_review_path(proposta))
    end
  end

  # CYRA-817 — le accettate che aspettano di finire nei documenti erano stampate TUTTE insieme: da
  # sole facevano una quarantina di schermate, spingevano in fondo la cronologia degli scarti e non
  # c'era modo di cercarne una — la ricerca in cima dichiara di lavorare «fra le proposte in attesa»,
  # ed è un'altra cosa.
  describe "GET /member/knowledge/reviews — da archiviare (CYRA-817)" do
    # Accettate a un'ora di distanza l'una dall'altra: l'ordine è la più recente in cima, quindi
    # "Da archiviare 0" apre l'elenco e l'ultima accettata lo chiude.
    def da_archiviare(quante)
      Array.new(quante) do |i|
        create(:knowledge_page, organization: org, project: project,
                                title: "Da archiviare #{i}", reviewed_at: (i + 1).hours.ago)
      end
    end

    def righe(body) = Nokogiri::HTML(body).css('[data-test="knowledge-review-to-file-row"]')

    it "divide in pagine le accettate da archiviare invece di stamparle tutte insieme" do
      da_archiviare(13)
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(righe(response.body).size).to eq(Pagination::DEFAULT_PER)
      expect(response.body).to include("Da archiviare 0")
      expect(response.body).not_to include("Da archiviare 12")
    end

    it "la pagina successiva mostra le accettate rimaste" do
      da_archiviare(13)
      sign_in(owner)

      get member_knowledge_reviews_path(to_file_page: 2)

      expect(response.body).to include("Da archiviare 12")
      expect(response.body).not_to include("Da archiviare 0")
    end

    # Il totale è il numero della sezione intera, non delle righe caricate: chi guarda deve sapere
    # quante ne aspettano davvero mentre ne legge dieci.
    it "il conteggio in alto resta quello di tutte le accettate, non della pagina" do
      da_archiviare(13)
      sign_in(owner)

      get member_knowledge_reviews_path

      chip = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-review-stat-to-file"]').text
      expect(chip).to include("13")
      expect(righe(response.body).size).to eq(Pagination::DEFAULT_PER)
    end

    # Due elenchi sulla stessa pagina, due cursori: sfogliare le accettate non deve far ripartire la
    # coda delle proposte da capo (e viceversa).
    it "sfogliare le accettate non muove la coda delle proposte" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      da_archiviare(13)
      sign_in(owner)

      get member_knowledge_reviews_path(to_file_page: 2)

      expect(response.body).to include("Proposta in attesa")
      expect(response.body).to include("Da archiviare 12")
    end

    it "cerca fra le accettate per titolo" do
      create(:knowledge_page, organization: org, project: project,
                              title: "Trappola dei worktree", reviewed_at: Time.current)
      create(:knowledge_page, organization: org, project: project,
                              title: "Come si scrive una guida", reviewed_at: 1.hour.ago)
      sign_in(owner)

      get member_knowledge_reviews_path(to_file_q: "trappola")

      expect(response.body).to include("Trappola dei worktree")
      expect(response.body).not_to include("Come si scrive una guida")
    end

    # La ricerca in cima resta quella delle proposte: cercare fra le accettate non ne cambia il
    # significato e non svuota l'altra sezione.
    it "la ricerca fra le accettate non tocca la coda delle proposte" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      create(:knowledge_page, organization: org, project: project,
                              title: "Trappola dei worktree", reviewed_at: Time.current)
      sign_in(owner)

      get member_knowledge_reviews_path(to_file_q: "trappola")

      expect(response.body).to include("Proposta in attesa")
      expect(response.body).to include("Trappola dei worktree")
    end

    it "cercando fra le proposte le accettate restano al loro posto" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      create(:knowledge_page, organization: org, project: project,
                              title: "Da archiviare 0", reviewed_at: Time.current)
      sign_in(owner)

      get member_knowledge_reviews_path(q: "proposta")

      expect(response.body).to include("Proposta in attesa")
      expect(response.body).to include("Da archiviare 0")
    end

    it "a ricerca senza corrispondenze dice quante accettate aspettano davvero" do
      da_archiviare(3)
      sign_in(owner)

      get member_knowledge_reviews_path(to_file_q: "niente-che-esista")

      expect(righe(response.body)).to be_empty
      expect(response.body).to include(
        ERB::Util.html_escape(I18n.t("member.knowledge.reviews.to_file_no_results_body", count: 3))
      )
    end

    # Il modulo di ricerca delle accettate si porta dietro lo stato dell'altra sezione: senza, cercare
    # qui azzererebbe il filtro delle proposte, che è dichiarato a parte.
    it "il modulo di ricerca delle accettate conserva il filtro delle proposte" do
      create(:knowledge_page, organization: org, project: project, title: "Da archiviare 0", reviewed_at: Time.current)
      sign_in(owner)

      get member_knowledge_reviews_path(q: "trappola")

      form = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-review-to-file-toolbar"] form')
      expect(form.at_css('input[type="hidden"][name="q"]')["value"]).to eq("trappola")
      expect(form.at_css('input[name="to_file_q"]')).to be_present
    end

    # L'altra metà: il modulo della coda porta con sé lo stato del riquadro. I campi partono
    # dall'indirizzo e ci vengono riallineati prima dell'invio (ui--url-state), perché il riquadro si
    # aggiorna da solo e questa barra non viene ridisegnata quando lui cambia pagina.
    it "il modulo di ricerca delle proposte porta con sé la pagina delle accettate" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      da_archiviare(13)
      sign_in(owner)

      get member_knowledge_reviews_path(to_file_page: 2)

      campo = Nokogiri::HTML(response.body)
                .at_css('[data-test="knowledge-review-toolbar"] input[name="to_file_page"]')
      expect(campo["value"]).to eq("2")
      expect(campo["disabled"]).to be_nil
      expect(campo["data-url-state-param"]).to eq("to_file_page")
    end

    # Un parametro vuoto nell'indirizzo è rumore, e per i filtri ricordati «presente e vuoto» non
    # vuol dire «assente»: il campo senza valore è disabilitato, quindi non viaggia affatto.
    it "senza stato del riquadro quei campi non viaggiano" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      da_archiviare(1)
      sign_in(owner)

      get member_knowledge_reviews_path

      campo = Nokogiri::HTML(response.body)
                .at_css('[data-test="knowledge-review-toolbar"] input[name="to_file_q"]')
      expect(campo["disabled"]).to be_present
    end

    # Expected dello scenario: dalle sezioni si arriva direttamente, senza attraversare l'elenco.
    it "dai conteggi in alto si salta direttamente al riquadro" do
      da_archiviare(1)
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      sign_in(owner)

      get member_knowledge_reviews_path

      html = Nokogiri::HTML(response.body)
      salto = html.at_css('[data-test="knowledge-review-stat-to-file"]')
      expect(salto.name).to eq("a")
      expect(salto["href"]).to eq("#knowledge-review-to-file")
      expect(html.at_css("#knowledge-review-to-file")).to be_present
      expect(html.at_css("#knowledge-review-waiting")).to be_present
    end

    # Audit Turbo del ticket: sfogliare le accettate chiede SOLO quel riquadro, e la risposta non
    # ricostruisce la coda delle proposte né la cronologia degli scarti.
    it "chiedendo solo il riquadro non ricostruisce le altre sezioni" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      da_archiviare(13)
      sign_in(owner)

      get member_knowledge_reviews_path(to_file_page: 2), headers: { "Turbo-Frame" => "knowledge-review-to-file" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Da archiviare 12")
      expect(response.body).not_to include("Proposta in attesa")
      expect(Nokogiri::HTML(response.body).at_css('[data-test="knowledge-review-waiting"]')).to be_nil
      expect(Nokogiri::HTML(response.body).at_css("turbo-frame#knowledge-review-to-file")).to be_present
    end

    # Senza JS il riquadro non esiste come frame: lo stesso indirizzo deve rendere la pagina intera
    # con le accettate alla pagina chiesta.
    it "lo stesso indirizzo senza il riquadro rende la pagina intera" do
      create(:knowledge_page, :in_review, organization: org, project: project, title: "Proposta in attesa")
      da_archiviare(13)
      sign_in(owner)

      get member_knowledge_reviews_path(to_file_page: 2)

      expect(response.body).to include("Proposta in attesa")
      expect(Nokogiri::HTML(response.body).at_css('[data-test="knowledge-review-waiting"]')).to be_present
    end

    it "non mostra fra le accettate le pagine dei progetti che non vedo" do
      altro_progetto = create(:project, organization: org, name: "Progetto che non vedo")
      create(:knowledge_page, organization: org, project: altro_progetto,
                              title: "Accettata altrove", reviewed_at: Time.current)
      sign_in(member)

      get member_knowledge_reviews_path

      expect(response.body).not_to include("Accettata altrove")
    end
  end

  describe "POST approve" do
    it "pubblica la proposta e torna alla coda" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project)
      sign_in(owner)

      post approve_member_knowledge_review_path(proposta)

      expect(response).to redirect_to(member_knowledge_reviews_path)
      expect(proposta.reload).to be_status_published
      expect(proposta.reviewed_by).to eq(owner)
    end

    it "da lì in poi la pagina è visibile fra le altre" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project, title: "Ora pubblica")
      sign_in(owner)

      post approve_member_knowledge_review_path(proposta)
      get member_knowledge_pages_path

      expect(response.body).to include("Ora pubblica")
    end

    it "una proposta di un progetto che non vedo non è raggiungibile" do
      altro_progetto = create(:project, organization: org)
      nascosta = create(:knowledge_page, :in_review, organization: org, project: altro_progetto)
      sign_in(member)

      post approve_member_knowledge_review_path(nascosta)

      expect(response).to have_http_status(:not_found)
      expect(nascosta.reload).to be_status_in_review
    end

    # CYRA-560 Scenario 2 — decidere sulla trentesima proposta non deve riportare all'inizio della
    # coda: si torna alla pagina, alla ricerca e ai filtri da cui è partita la decisione.
    it "torna alla pagina della coda da cui è arrivata la decisione" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project)
      sign_in(owner)

      post approve_member_knowledge_review_path(proposta, page: 3, q: "worktree", project_id: [ project.id ])

      expect(response).to redirect_to(
        member_knowledge_reviews_path(page: "3", q: "worktree", project_id: [ project.id.to_s ])
      )
    end
  end

  describe "POST reject" do
    it "scarta la proposta senza cancellarla" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project)
      sign_in(owner)

      expect { post reject_member_knowledge_review_path(proposta) }.not_to change(Knowledge::Page, :count)

      expect(response).to redirect_to(member_knowledge_reviews_path)
      expect(proposta.reload).to be_status_rejected
    end

    it "la scartata resta elencata a parte, non fra quelle in attesa" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project, title: "Nota scartata")
      sign_in(owner)

      post reject_member_knowledge_review_path(proposta)
      get member_knowledge_reviews_path

      expect(response.body).to include("Nota scartata")
      expect(response.body).to include(I18n.t("member.knowledge.reviews.rejected_title"))
    end

    it "la scartata non torna nella ricerca delle pagine" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project, title: "Nota scartata")
      sign_in(owner)

      post reject_member_knowledge_review_path(proposta)
      get member_knowledge_pages_path

      expect(response.body).not_to include("Nota scartata")
    end

    it "torna alla pagina della coda da cui è arrivata la decisione (CYRA-560)" do
      proposta = create(:knowledge_page, :in_review, organization: org, project: project)
      sign_in(owner)

      post reject_member_knowledge_review_path(proposta, page: 2)

      expect(response).to redirect_to(member_knowledge_reviews_path(page: "2"))
    end
  end

  # CYRA-768 — la coda delle pagine oltre la data di rilettura: senza, una decisione accettata resta
  # vera per sempre e viene citata come se fosse ancora attuale.
  describe "coda delle pagine da rileggere" do
    def scaduta(kind: :decision, titolo: "Scelta del proxy")
      create(:knowledge_page, kind: kind, organization: org, project: project, title: titolo)
        .tap { |page| page.update_columns(review_after: 1.day.ago) }
    end

    it "elenca le pagine oltre la data con il chip del totale" do
      page = scaduta
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response.body).to include(page.title)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-test="knowledge-review-needs-review-row"]')).to be_present
      expect(html.at_css('[data-test="knowledge-review-stat-needs-review"]').text).to include("1")
    end

    it "non elenca una pagina che non è ancora arrivata alla data" do
      futura = create(:knowledge_page, :decision, organization: org, project: project, title: "Ancora fresca")
      futura.update_columns(review_after: 30.days.from_now)
      sign_in(owner)

      get member_knowledge_reviews_path

      expect(response.body).not_to include("Ancora fresca")
    end

    it "non elenca le pagine di un progetto che non vedo" do
      altro_progetto = create(:project, organization: org)
      nascosta = create(:knowledge_page, :decision, organization: org, project: altro_progetto, title: "Non mia")
      nascosta.update_columns(review_after: 1.day.ago)
      sign_in(member)

      get member_knowledge_reviews_path

      expect(response.body).not_to include("Non mia")
    end

    it "confermando, la data riparte e la pagina esce dalla coda" do
      page = scaduta
      sign_in(owner)

      post confirm_member_knowledge_review_path(page)

      expect(response).to redirect_to(member_knowledge_reviews_path)
      expect(page.reload).not_to be_needs_review
      expect(page.review_after).to be > Time.current
    end

    it "una pagina di un progetto che non vedo non è confermabile" do
      altro_progetto = create(:project, organization: org)
      nascosta = create(:knowledge_page, :decision, organization: org, project: altro_progetto)
      nascosta.update_columns(review_after: 1.day.ago)
      sign_in(member)

      post confirm_member_knowledge_review_path(nascosta)

      expect(response).to have_http_status(:not_found)
      expect(nascosta.reload).to be_needs_review
    end

    it "chi non può gestire la pagina riceve il motivo e la data resta dov'era" do
      altro = create(:account)
      create(:membership, account: altro, organization: org, role: :member)
      create(:project_membership, account: altro, project: project)
      page = scaduta

      sign_in(altro)
      post confirm_member_knowledge_review_path(page)

      expect(response).to redirect_to(member_knowledge_reviews_path)
      expect(flash[:alert]).to eq(I18n.t("member.knowledge.errors.review_forbidden"))
      expect(page.reload).to be_needs_review
    end
  end

  describe "GET /member/guides/knowledge-review" do
    it "risponde con la guida" do
      sign_in(member)

      get member_guides_knowledge_review_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("member.guides.knowledge_review.title"))
    end
  end
end
