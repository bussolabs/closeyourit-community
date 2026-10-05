# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Ideas", type: :request do
  let(:org) { create(:organization) }
  # Gli attori nascono con la loro membership solo quando un esempio li nomina (CYRA-551): quasi
  # ogni esempio ne usa uno, e un `before` comune li faceva pagare tutti a tutti.
  let(:owner) { account_with_membership(:owner) }
  let(:member) { account_with_membership(:member, on_project: true) }
  # outsider: membro dell'org ma SENZA accesso al progetto → non vede l'idea (scoping).
  let(:outsider) { account_with_membership(:member) }
  let(:other_org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project, author: member) }

  def account_with_membership(role, on_project: false)
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: role)
      create(:project_membership, account: account, project: project) if on_project
    end
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "GET /member/ideas" do
    it "non autenticato → redirect login" do
      get member_ideas_path
      expect(response).to redirect_to(login_path)
    end

    it "risponde con 200 e mostra solo le idee dei progetti visibili (anti-leak)" do
      visible = create(:idea, organization: org, project: project, title: "Idea visibile 1001")
      hidden_project = create(:project, organization: org)
      hidden = create(:idea, organization: org, project: hidden_project, title: "Idea nascosta 1002")

      sign_in(member)
      get member_ideas_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(visible.title)
      expect(response.body).not_to include(hidden.title)
    end

    # DESIGN.md T12 — a count reads as the number followed by the word, like on every page.
    it "writes each count as the number followed by the word" do
      sign_in(member)
      get member_ideas_path

      labels = Nokogiri::HTML(response.body).css("[data-test^='ideas-count-']").map { |el| el.text.squish }
      expect(labels).to all(match(/\A\d+ \p{Ll}/))
    end

    it "filtra per status e per progetto (param array)" do
      open_idea = create(:idea, organization: org, project: project, title: "Aperta 2001")
      archived_idea = create(:idea, :archived, organization: org, project: project, title: "Archiviata 2002")

      sign_in(owner)
      get member_ideas_path, params: { status: [ "archived" ] }

      expect(response.body).to include(archived_idea.title)
      expect(response.body).not_to include("Aperta 2001")

      get member_ideas_path, params: { project_id: [ project.id ] }
      expect(response.body).to include(open_idea.title)
    end

    it "cerca su titolo, problema e soluzione (q ILIKE)" do
      create(:idea, organization: org, project: project, title: "Modalità scura 3001", problem: "tema notte")
      create(:idea, organization: org, project: project, title: "Altro 3002", solution: "niente di rilevante", problem: "generico")

      sign_in(owner)
      get member_ideas_path, params: { q: "notte" }

      expect(response.body).to include("Modalità scura 3001")
      expect(response.body).not_to include("Altro 3002")
    end

    # CYRA-360 Scenario 1 — la bacheca ordinava per voti, che erano zero ovunque: di fatto era un
    # ordine per data che nessuno aveva dichiarato. Ora in cima ci sono le idee che si sono mosse
    # davvero (discussione, casi d'uso, modifiche), e il voto non sposta niente.
    it "ordina per ultimo movimento e i voti non spostano nessuna riga" do
      stop = create(:idea, organization: org, project: project, title: "Ferma 4001",
                            created_at: 1.hour.ago, updated_at: 1.hour.ago)
      mossa = create(:idea, organization: org, project: project, title: "Mossa 4002",
                            created_at: 2.days.ago, updated_at: 2.days.ago)
      create(:idea_comment, idea: mossa, organization: org)

      sign_in(owner)
      get member_ideas_path
      expect(response.body.index("Mossa 4002")).to be < response.body.index("Ferma 4001")

      # Tre voti sull'idea ferma: resta dov'era, perché il voto dice interesse, non priorità.
      # Le query per-voto sono quelle del factory (una validazione di membership a testa), non
      # quelle della lista sotto esame: l'N+1 della GET resta sorvegliato.
      allow_n_plus_one { 3.times { create(:idea_vote, idea: stop) } }
      get member_ideas_path
      expect(response.body.index("Mossa 4002")).to be < response.body.index("Ferma 4001")
    end

    # CYRA-370 — la lista diceva soltanto che un'idea era «Convertita»: per sapere in quale ticket
    # fosse finita si aprivano le idee una per una, mentre la colonna dei voti restava a zero su
    # tutte le righe. Quel posto ora lo prende il ticket nato dalla conversione.
    describe "colonna del ticket sulle righe convertite" do
      def pagina
        Nokogiri::HTML(response.body)
      end

      it "filtrando le convertite ogni riga porta il codice del suo ticket, cliccabile" do
        prima = seconda = nil
        # Fixture bulk nel setup: ogni :converted costruisce un ticket completo (stato, priorità,
        # reporter) e le query per-record del factory non sono l'N+1 della lista sotto esame —
        # quello lo sorveglia Prosopite sulla GET, dove due righe convertite bastano a scoprirlo.
        allow_n_plus_one do
          prima = create(:idea, :converted, organization: org, project: project, title: "Convertita 5001")
          seconda = create(:idea, :converted, organization: org, project: project, title: "Convertita 5002")
        end

        sign_in(owner)
        get member_ideas_path, params: { status: [ "converted" ] }

        link = pagina.css("[data-test='idea-ticket-link']")
        expect(link.map { |a| a.text.strip }).to match_array([ prima.ticket.code, seconda.ticket.code ])
        expect(link.map { |a| a["href"] })
          .to match_array([ member_ticket_path(prima.ticket), member_ticket_path(seconda.ticket) ])
      end

      # C79 — archived ideas are faded so the open ones stand out; they stay readable and clickable.
      it "fades the archived rows and only those" do
        create(:idea, organization: org, project: project, title: "Still open 5010")
        create(:idea, organization: org, project: project, title: "Shelved 5011", status: :archived)

        sign_in(owner)
        get member_ideas_path

        rows = pagina.css("[data-test='idea-row']")
        faded = rows.select { |row| row["class"].to_s.include?("ui-table-row--faded") }.map(&:text)
        expect(faded.size).to eq(1)
        expect(faded.first).to include("Shelved 5011")
      end

      it "sulle righe non convertite la colonna resta vuota" do
        create(:idea, organization: org, project: project, title: "Aperta 5003")

        sign_in(owner)
        get member_ideas_path, params: { status: [ "open" ] }

        expect(response.body).to include("Aperta 5003")
        expect(pagina.at_css("[data-test='idea-ticket-cell']")).to be_present
        expect(pagina.at_css("[data-test='idea-ticket-link']")).to be_nil
      end

      it "convertita col ticket già eliminato: la riga resta, senza link" do
        orfana = create(:idea, :converted, organization: org, project: project, title: "Orfana 5004")
        orfana.ticket.destroy!

        sign_in(owner)
        get member_ideas_path, params: { status: [ "converted" ] }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Orfana 5004")
        expect(pagina.at_css("[data-test='idea-ticket-link']")).to be_nil
      end

      it "shows votes and ticket side by side in the header" do
        create(:idea, organization: org, project: project, title: "Aperta 5005")

        sign_in(owner)
        get member_ideas_path

        attese = %w[col_title col_project col_author col_votes col_comments col_status col_ticket col_last_activity]
                 .map { |key| I18n.t("member.ideas.#{key}") } << I18n.t("ui.table.open_column")
        # The visible header text only: a hint icon carries its tooltip in an SVG <title>.
        headers = pagina.css("thead th").map { |th| th.dup.tap { |cell| cell.css("svg").remove }.text.strip }
        expect(headers).to eq(attese)
        expect(pagina.at_css("[data-test='idea-votes-cell']")).to be_present
      end
    end

    # The default order is declared on the last activity header, not in the toolbar.
    it "declares the default order on the last activity header" do
      create(:idea, organization: org, project: project, title: "Open 6001")

      sign_in(owner)
      get member_ideas_path

      page_html = Nokogiri::HTML(response.body)
      expect(page_html.at_css("[data-test='sort-last_activity-hint'] title").text).to eq(I18n.t("member.ideas.sort_note"))
      expect(page_html.at_css("[data-test='ideas-sort-note']")).to be_nil
    end

    describe "sortable columns" do
      let(:other_project) { create(:project, organization: org, name: "Zeta", key: "ZET") }

      before { create(:project_membership, account: owner, project: other_project) }

      def row_titles
        Nokogiri::HTML(response.body).css("[data-test='idea-row'] > :first-child a").map { |a| a.text.strip }
      end

      it "every data column has a sort link" do
        create(:idea, organization: org, project: project)

        sign_in(owner)
        get member_ideas_path

        page_html = Nokogiri::HTML(response.body)
        %w[title project author comments status ticket last_activity].each do |key|
          expect(page_html.at_css("[data-test='sort-#{key}']")).to be_present, "missing sort-#{key}"
        end
      end

      it "sorts by title in both directions" do
        create(:idea, organization: org, project: project, title: "Beta idea")
        create(:idea, organization: org, project: project, title: "alpha idea")

        sign_in(owner)
        get member_ideas_path, params: { sort: "title" }
        expect(row_titles).to eq([ "alpha idea", "Beta idea" ])

        get member_ideas_path, params: { sort: "-title" }
        expect(row_titles).to eq([ "Beta idea", "alpha idea" ])
      end

      it "sorts by project name" do
        create(:idea, organization: org, project: other_project, title: "In Zeta")
        create(:idea, organization: org, project: project, title: "In first project")
        project.update!(name: "Alpha")

        sign_in(owner)
        get member_ideas_path, params: { sort: "project" }
        expect(row_titles).to eq([ "In first project", "In Zeta" ])
      end

      it "sorts by comments count, busiest first on the first click" do
        quiet = create(:idea, organization: org, project: project, title: "Quiet")
        busy = create(:idea, organization: org, project: project, title: "Busy")
        allow_n_plus_one { 2.times { create(:idea_comment, idea: busy, organization: org) } }

        sign_in(owner)
        get member_ideas_path, params: { sort: "-comments" }
        expect(row_titles).to eq([ busy.title, quiet.title ])
      end

      it "sorts by ticket number and keeps ideas without a ticket last" do
        low = create(:ticket, organization: org, project: project)
        high = create(:ticket, organization: org, project: project)
        create(:idea, :converted, organization: org, project: project, title: "High", ticket: high)
        create(:idea, organization: org, project: project, title: "No ticket")
        create(:idea, :converted, organization: org, project: project, title: "Low", ticket: low)

        sign_in(owner)
        get member_ideas_path, params: { sort: "ticket" }
        expect(row_titles).to eq([ "Low", "High", "No ticket" ])

        get member_ideas_path, params: { sort: "-ticket" }
        expect(row_titles).to eq([ "High", "Low", "No ticket" ])
      end

      it "an unknown sort key keeps the last activity order" do
        create(:idea, organization: org, project: project, title: "Older", updated_at: 2.days.ago)
        create(:idea, organization: org, project: project, title: "Newer", updated_at: 1.hour.ago)

        sign_in(owner)
        get member_ideas_path, params: { sort: "votes_count; DROP TABLE ideas_ideas" }
        expect(row_titles).to eq([ "Newer", "Older" ])
      end
    end

    it "the empty state teaches with an example and offers to propose the first idea" do
      sign_in(owner)
      get member_ideas_path

      empty = Nokogiri::HTML(response.body).at_css("[data-test='ideas-empty']")
      expect(empty.at_css("[data-test='empty-example']").text.strip).to eq(I18n.t("member.ideas.empty_example"))
      expect(empty.at_css("a[href='#{new_member_idea_path}']")).to be_present
    end
  end

  describe "GET /member/ideas/:id" do
    it "risponde con 200 per chi vede il progetto" do
      sign_in(member)
      get member_idea_path(idea)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(idea.title)
    end

    it "membro senza accesso al progetto → 404 (BOLA)" do
      sign_in(outsider)
      get member_idea_path(idea)
      expect(response).to have_http_status(:not_found)
    end

    it "account di un'altra org → 404 (BOLA)" do
      stranger = create(:account)
      create(:membership, account: stranger, organization: other_org, role: :owner)
      sign_in(stranger)
      get member_idea_path(idea)
      expect(response).to have_http_status(:not_found)
    end

    it "converted idea: the ticket and the conversion date sit in the Details, not in a banner" do
      converted = create(:idea, :converted, organization: org, project: project)
      sign_in(owner)
      get member_idea_path(converted)
      html = Capybara.string(response.body)
      expect(html).to have_no_css("[data-test='idea-converted-banner']")
      expect(html).to have_css("[data-test='idea-details'] [data-test='idea-ticket']", text: converted.ticket.code)
      expect(html).to have_css("[data-test='idea-details'] [data-test='idea-converted-on']")
      expect(html).to have_css("[data-test='idea-open-ticket']")
    end

    # CYRA-360 Scenario 2 — il voto era un pulsantino defilato che non dichiarava nulla. Ora ha un
    # riquadro proprio che dice a cosa serve (e a cosa NON serve) e chi l'ha già dato.
    describe "riquadro dell'interesse" do
      def pagina
        Nokogiri::HTML(response.body)
      end

      it "dichiara cosa comporta votare e mostra chi ha votato" do
        votante = create(:account, name: "Dana Kim")
        create(:membership, account: votante, organization: org, role: :member)
        create(:idea_vote, idea: idea, account: votante)

        sign_in(member)
        get member_idea_path(idea)

        blocco = pagina.at_css("[data-test='idea-interest']")
        expect(blocco.text).to include(I18n.t("member.ideas.interest.explainer"))
        expect(pagina.at_css("[data-test='idea-votes-count']").text.strip).to eq("1")
        expect(pagina.at_css("[data-test='idea-voters']").text).to include("Dana Kim")
        expect(pagina.at_css("[data-test='idea-vote']")).to be_present
      end

      it "senza voti l'elenco è vuoto e lo dice" do
        sign_in(member)
        get member_idea_path(idea)

        expect(pagina.at_css("[data-test='idea-voters']")).to be_nil
        expect(pagina.at_css("[data-test='idea-voters-empty']").text.strip)
          .to eq(I18n.t("member.ideas.interest.empty"))
      end

      it "su un'idea congelata restano i votanti ma non il pulsante" do
        converted = create(:idea, :converted, organization: org, project: project)
        votante = create(:account, name: "Rita Sala")
        create(:membership, account: votante, organization: org, role: :member)
        create(:idea_vote, idea: converted, account: votante)

        sign_in(member)
        get member_idea_path(converted)

        expect(pagina.at_css("[data-test='idea-voters']").text).to include("Rita Sala")
        expect(pagina.at_css("[data-test='idea-vote']")).to be_nil
      end
    end

    it "mostra il blocco Audit e la cronologia attività quando ci sono eventi" do
      Ideas::UpdateIdea.call(idea: idea, params: { title: "Nuovo titolo", problem: idea.problem }, actor: owner)
      sign_in(owner)
      get member_idea_path(idea)
      expect(response.body).to include("idea-audit", "activity-modal")
    end

    # CYRA-371 — qui si argomenta una decisione di prodotto: il campo deve reggere il pensiero intero,
    # e un intervento lungo non deve schiacciare il resto della pagina.
    describe "discussione" do
      def pagina
        Nokogiri::HTML(response.body)
      end

      it "il contatore del form dichiara il tetto delle idee, non quello dei commenti dei ticket" do
        sign_in(member)
        get member_idea_path(idea)

        campo = pagina.at_css("[data-controller='char-counter']")
        expect(campo["data-char-counter-max-value"]).to eq(Ideas::Constants::COMMENT_MAX_CHARS.to_s)
      end

      it "un intervento lungo arriva ritagliato, col comando per vederlo tutto" do
        testo = "x" * 3_000
        create(:idea_comment, idea: idea, organization: org, body: testo)

        sign_in(member)
        get member_idea_path(idea)

        expect(pagina.at_css("[data-test='idea-comment-toggle']")).to be_present
        expect(response.body).to include(I18n.t("member.ideas.comments.show_all"))
        # Il ritaglio è visivo: il testo in pagina resta intero, non troncato dal server.
        expect(response.body).to include(testo)
      end

      it "un commento breve non porta alcun comando: sarebbe rumore" do
        create(:idea_comment, idea: idea, organization: org, body: "Serve anche su mobile")

        sign_in(member)
        get member_idea_path(idea)

        expect(pagina.at_css("[data-test='idea-comment-toggle']")).to be_nil
      end
    end

    # CYRA-369 — su un'idea andata a buon fine l'app proponeva solo di distruggerla.
    describe "barra azioni" do
      def pagina
        Nokogiri::HTML(response.body)
      end

      it "idea convertita: l'azione principale apre il ticket nato dalla conversione" do
        converted = create(:idea, :converted, organization: org, project: project, author: member)
        sign_in(member)
        get member_idea_path(converted)

        apri = pagina.at_css("[data-test='idea-open-ticket']")
        expect(apri).to be_present
        expect(apri["href"]).to eq(member_ticket_path(converted.ticket))
        expect(apri.text).to include(converted.ticket.code)
      end

      it "idea convertita: eliminare non è più l'unica azione, sta nel menu secondario" do
        converted = create(:idea, :converted, organization: org, project: project, author: member)
        sign_in(member)
        get member_idea_path(converted)

        doc = pagina
        menu = doc.at_css("[data-test='idea-more-menu']")
        expect(menu).to be_present
        expect(menu.at_css("[data-test='idea-delete']")).to be_present
        # Un solo Elimina in pagina, e sta dentro il menu: non è rimasto in barra.
        expect(doc.css("[data-test='idea-delete']").size).to eq(1)
      end

      it "idea aperta: eliminare sta nel menu, lontano dal pulsante che converte" do
        sign_in(owner)
        get member_idea_path(idea)

        doc = pagina
        expect(doc.at_css("[data-test='idea-convert']")).to be_present
        menu = doc.at_css("[data-test='idea-more-menu']")
        expect(menu.at_css("[data-test='idea-delete']")).to be_present
        expect(menu.at_css("[data-test='idea-convert']")).to be_nil
        expect(doc.css("[data-test='idea-delete']").size).to eq(1)
      end

      it "idea archiviata: eliminare sta comunque nel menu secondario" do
        archived = create(:idea, :archived, organization: org, project: project, author: member)
        sign_in(member)
        get member_idea_path(archived)

        doc = pagina
        expect(doc.at_css("[data-test='idea-reopen']")).to be_present
        expect(doc.at_css("[data-test='idea-more-menu']").at_css("[data-test='idea-delete']")).to be_present
      end

      it "la conferma sull'idea convertita avvisa che si perde il collegamento al ticket" do
        converted = create(:idea, :converted, organization: org, project: project, author: member)
        sign_in(member)
        get member_idea_path(converted)

        conferma = pagina.at_css("[data-test='idea-delete']")["data-turbo-confirm"]
        expect(conferma).to eq(I18n.t("member.ideas.delete_confirm_converted", code: converted.ticket.code))
        expect(conferma).to include(converted.ticket.code)
      end

      it "la conferma sull'idea aperta resta quella standard" do
        sign_in(member)
        get member_idea_path(idea)

        conferma = pagina.at_css("[data-test='idea-delete']")["data-turbo-confirm"]
        expect(conferma).to eq(I18n.t("member.ideas.delete_confirm"))
      end

      it "convertita col ticket già eliminato: nessun link al ticket e conferma standard" do
        orfana = create(:idea, :converted, organization: org, project: project, author: member)
        orfana.ticket.destroy!
        orfana.reload

        sign_in(member)
        get member_idea_path(orfana)

        doc = pagina
        expect(doc.at_css("[data-test='idea-open-ticket']")).to be_nil
        expect(doc.at_css("[data-test='idea-delete']")["data-turbo-confirm"]).to eq(I18n.t("member.ideas.delete_confirm"))
      end

      it "chi non può eliminare non vede nessun menu secondario" do
        altrui = create(:idea, organization: org, project: project, author: owner)
        create(:project_membership, account: outsider, project: project)
        sign_in(outsider)
        get member_idea_path(altrui)

        doc = pagina
        expect(doc.at_css("[data-test='idea-more-menu']")).to be_nil
        expect(doc.at_css("[data-test='idea-delete']")).to be_nil
      end
    end
  end

  describe "GET /member/ideas/new" do
    it "risponde con 200" do
      sign_in(member)
      get new_member_idea_path
      expect(response).to have_http_status(:ok)
    end

    it "con ?project_id di un progetto visibile → progetto bloccato (no select)" do
      sign_in(member)
      get new_member_idea_path(project_id: project.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="idea-project-locked"')
      expect(response.body).to include('name="locked_project"')
      expect(response.body).not_to include('data-test="idea-project"')
    end

    # CYRA-167 — il pannello delle idee simili è agganciato al titolo; senza JS resta nascosto e il
    # modulo è identico a prima (il salvataggio non dipende mai dal suggerimento).
    it "monta il pannello delle idee simili sul campo del titolo" do
      sign_in(member)
      get new_member_idea_path

      html = Nokogiri::HTML(response.body)
      expect(html.at_css('[data-controller="idea-duplicates"]')["data-idea-duplicates-url-value"])
        .to eq(duplicates_member_ideas_path)
      panel = html.at_css('[data-test="idea-duplicates-panel"]')
      expect(panel).to be_present
      # Nasce nascosto: senza JS non compare niente e il modulo resta quello di prima.
      expect(panel.attributes).to have_key("hidden")
    end

    it "in modifica NON mostra il pannello delle idee simili (vale solo per la proposta)" do
      sign_in(member)
      get edit_member_idea_path(idea)

      expect(response.body).not_to include('data-controller="idea-duplicates"')
    end

    it "con ?project_id di un progetto NON visibile → form normale (nessun blocco, anti-BOLA)" do
      hidden_project = create(:project, name: "Hidden Idea Project 9001", organization: org)
      sign_in(member)
      get new_member_idea_path(project_id: hidden_project.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="idea-project"')
      expect(response.body).not_to include('data-test="idea-project-locked"')
      expect(response.body).not_to include("value=\"#{hidden_project.id}\"")
    end
  end

  describe "POST /member/ideas" do
    it "crea l'idea con autore = account corrente e reindirizza alla show" do
      sign_in(member)
      expect do
        post member_ideas_path, params: { project_id: project.id, title: "Dark mode",
                                          problem: "La dashboard acceca", solution: "Tema scuro",
                                          stakeholders: "Team Mobile, Clienti" }
      end.to change(Ideas::Idea, :count).by(1)

      created = Ideas::Idea.order(:created_at).last
      expect(created.author).to eq(member)
      expect(created.problem).to eq("La dashboard acceca")
      expect(created.solution).to eq("Tema scuro")
      # stakeholder dal form: stringa comma-separated → split → array normalizzato
      expect(created.stakeholders).to eq([ "Team Mobile", "Clienti" ])
      expect(response).to redirect_to(member_idea_path(created))
    end

    it "validazione fallita → 422 e nessuna idea" do
      sign_in(member)
      expect do
        post member_ideas_path, params: { project_id: project.id, title: "", problem: "x" }
      end.not_to change(Ideas::Idea, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "progetto non visibile → 422 con errore (anti-BOLA dal service)" do
      hidden_project = create(:project, organization: org)
      sign_in(member)
      expect do
        post member_ideas_path, params: { project_id: hidden_project.id, title: "x", problem: "y" }
      end.not_to change(Ideas::Idea, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "da un progetto bloccato (locked_project) → idea collegata a quel progetto" do
      sign_in(member)
      expect do
        post member_ideas_path, params: { project_id: project.id, title: "Push", problem: "Notifiche", locked_project: "1" }
      end.to change(Ideas::Idea, :count).by(1)
      expect(Ideas::Idea.order(:created_at).last.project).to eq(project)
    end

    it "create fallito da progetto bloccato → ri-renderizza il form mantenendo il lock (422)" do
      sign_in(member)
      post member_ideas_path, params: { project_id: project.id, title: "", problem: "", locked_project: "1" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-test="idea-project-locked"')
    end
  end

  describe "GET /member/ideas/:id/edit" do
    it "l'autore può modificare la propria idea aperta" do
      sign_in(member)
      get edit_member_idea_path(idea)
      expect(response).to have_http_status(:ok)
    end

    it "un altro membro senza ideas.edit → redirect (denied)" do
      create(:project_membership, account: outsider, project: project)
      sign_in(outsider)
      get edit_member_idea_path(idea)
      expect(response).to have_http_status(:redirect)
    end

    it "owner (tutti i permessi) può modificare l'idea altrui" do
      sign_in(owner)
      get edit_member_idea_path(idea)
      expect(response).to have_http_status(:ok)
    end

    it "idea congelata → redirect alla show" do
      frozen = create(:idea, :archived, organization: org, project: project, author: member)
      sign_in(member)
      get edit_member_idea_path(frozen)
      expect(response).to redirect_to(member_idea_path(frozen))
    end
  end

  describe "PATCH /member/ideas/:id" do
    it "l'autore aggiorna titolo, problema e stakeholder" do
      sign_in(member)
      patch member_idea_path(idea), params: { title: "Nuovo", problem: "Problema nuovo", stakeholders: "Team A, Team B" }
      idea.reload
      expect(idea.title).to eq("Nuovo")
      expect(idea.problem).to eq("Problema nuovo")
      expect(idea.stakeholders).to eq([ "Team A", "Team B" ])
      expect(response).to redirect_to(member_idea_path(idea))
    end

    it "un altro membro senza permesso NON aggiorna" do
      create(:project_membership, account: outsider, project: project)
      sign_in(outsider)
      patch member_idea_path(idea), params: { title: "Hack", problem: "x" }
      expect(idea.reload.title).not_to eq("Hack")
      expect(response).to have_http_status(:redirect)
    end

    it "idea congelata → 422 (service R422-IDEA-002)" do
      frozen = create(:idea, :archived, organization: org, project: project, author: member, title: "Originale")
      sign_in(member)
      patch member_idea_path(frozen), params: { title: "Cambiato", problem: "x" }
      expect(frozen.reload.title).to eq("Originale")
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /member/ideas/:id" do
    it "l'autore elimina la propria idea" do
      target = create(:idea, organization: org, project: project, author: member)
      sign_in(member)
      expect { delete member_idea_path(target) }.to change(Ideas::Idea, :count).by(-1)
      expect(response).to redirect_to(member_ideas_path)
    end

    it "un altro membro senza ideas.delete NON elimina" do
      target = create(:idea, organization: org, project: project, author: member)
      create(:project_membership, account: outsider, project: project)
      sign_in(outsider)
      expect { delete member_idea_path(target) }.not_to change(Ideas::Idea, :count)
    end

    it "owner elimina l'idea altrui" do
      target = create(:idea, organization: org, project: project, author: member)
      sign_in(owner)
      expect { delete member_idea_path(target), params: { confirm: "1" } }.to change(Ideas::Idea, :count).by(-1)
    end
  end

  describe "PATCH /member/ideas/:id/archive + reopen" do
    it "l'autore archivia e riapre la propria idea" do
      sign_in(member)
      patch archive_member_idea_path(idea)
      expect(idea.reload).to be_status_archived

      patch reopen_member_idea_path(idea)
      expect(idea.reload).to be_status_open
    end

    it "idea convertita → nessuna transizione (alert)" do
      converted = create(:idea, :converted, organization: org, project: project, author: member)
      sign_in(member)
      patch archive_member_idea_path(converted)
      expect(converted.reload).to be_status_converted
    end

    it "un altro membro senza permesso NON archivia" do
      create(:project_membership, account: outsider, project: project)
      sign_in(outsider)
      patch archive_member_idea_path(idea)
      expect(idea.reload).to be_status_open
    end
  end

  # CYRA-167 — cercare tra le idee per significato, come già si fa su ticket e conoscenza: chi cerca
  # «scaricare i dati» deve trovare «Esportare i report in PDF», altrimenti la ripropone da capo.
  describe "GET /member/ideas (ricerca per significato)" do
    around do |example|
      old_url = ENV["EMBED_BASE_URL"]
      old_key = ENV["AI_API_KEY"]
      ENV["EMBED_BASE_URL"] = "http://embed.test:7997"
      ENV["AI_API_KEY"] = "test-key"
      example.run
    ensure
      old_url ? ENV["EMBED_BASE_URL"] = old_url : ENV.delete("EMBED_BASE_URL")
      old_key ? ENV["AI_API_KEY"] = old_key : ENV.delete("AI_API_KEY")
    end

    def embedded_idea(index, title:)
      create(:idea, organization: org, project: project, title: title).tap do |record|
        record.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                              embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
      end
    end

    def stub_semantic(vector: basis_vector(0), results: [ { "index" => 0, "relevance_score" => 0.9 } ])
      stub_request(:post, "http://embed.test:7997/embeddings")
        .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => vector } ] }.to_json)
      stub_request(:post, "http://embed.test:7997/rerank")
        .to_return(status: 200, body: { "results" => results }.to_json)
    end

    it "senza il parametro semantic cerca per significato (modalità predefinita)" do
      embedded_idea(0, title: "Esportare i report in PDF 5001")
      embedded_idea(1, title: "Cambiare i colori del tema 5002")
      stub_semantic

      sign_in(member)
      get member_ideas_path, params: { q: "scaricare i dati" }

      expect(response.body).to include("Esportare i report in PDF 5001")
      expect(response.body).not_to include("Cambiare i colori del tema 5002")
    end

    it "dichiara sopra i risultati la modalità in uso e la rende reversibile con un clic" do
      embedded_idea(0, title: "Esportare i report in PDF 5011")
      stub_semantic

      sign_in(member)
      get member_ideas_path, params: { q: "pdf", semantic: "1" }

      banner = Nokogiri::HTML(response.body).at_css('[data-test="ideas-search-mode-banner"]')
      expect(banner.text).to include(I18n.t("member.ideas.semantic.using_semantic"))
      switch = Nokogiri::HTML(response.body).at_css('[data-test="ideas-search-mode-switch"]')
      expect(switch["href"]).to include("semantic=0")
    end

    it "in «parole esatte» cerca su titolo, problema e soluzione e offre il ritorno al significato" do
      create(:idea, organization: org, project: project, title: "Modalità scura 5021", problem: "tema notte")
      create(:idea, organization: org, project: project, title: "Altro 5022", problem: "generico")

      sign_in(member)
      get member_ideas_path, params: { q: "notte", semantic: "0" }

      expect(response.body).to include("Modalità scura 5021")
      expect(response.body).not_to include("Altro 5022")
      banner = Nokogiri::HTML(response.body).at_css('[data-test="ideas-search-mode-banner"]')
      expect(banner.text).to include(I18n.t("member.ideas.semantic.using_exact"))
      expect(Nokogiri::HTML(response.body).at_css('[data-test="ideas-search-mode-switch"]')["href"]).to include("semantic=1")
    end

    it "trova comunque l'idea appena proposta, il cui indice non è ancora stato calcolato" do
      create(:idea, organization: org, project: project, title: "Notifiche push 5031")
      stub_semantic(results: [])

      sign_in(member)
      get member_ideas_path, params: { q: "push", semantic: "1" }

      expect(response.body).to include("Notifiche push 5031")
    end

    it "servizio non raggiungibile → risultati per parole esatte con avviso, mai un errore" do
      create(:idea, organization: org, project: project, title: "Esportare in PDF 5041")
      stub_request(:post, "http://embed.test:7997/embeddings").to_timeout

      sign_in(member)
      get member_ideas_path, params: { q: "Esportare", semantic: "1" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="ideas-semantic-degraded"')
      expect(response.body).to include("Esportare in PDF 5041")
    end
  end

  # Page refactor (2026-10-01): same shape as the projects, tickets and team activities pages.
  describe "page layout" do
    def html
      Capybara.string(response.body)
    end

    describe "list" do
      before { sign_in(owner) }

      it "shows a sortable votes column" do
        create(:idea, organization: org, project: project, title: "Few votes", votes_count: 1)
        create(:idea, organization: org, project: project, title: "Many votes", votes_count: 9)

        get member_ideas_path(sort: "-votes")

        expect(html).to have_css("[data-test='idea-votes-cell']", text: "9")
        expect(response.body.index("Many votes")).to be < response.body.index("Few votes")
      end

      it "shows one line of the problem under the title" do
        create(:idea, organization: org, project: project, title: "PDF export", problem: "Sales copy the **numbers** by hand.")

        get member_ideas_path

        expect(html).to have_css("[data-test='idea-problem-excerpt']", text: "Sales copy the numbers by hand.")
      end

      it "turns the status chips into filters that switch off on a second click" do
        create(:idea, organization: org, project: project, title: "Open one")
        create(:idea, :archived, organization: org, project: project, title: "Archived one")

        get member_ideas_path
        chip = html.find("a[data-test='ideas-count-archived']")
        expect(chip[:href]).to include("status")

        get chip[:href]
        expect(response.body).to include("Archived one")
        expect(response.body).not_to include("Open one")
        active = html.find("a[data-test='ideas-count-archived']")
        expect(active[:"aria-current"]).to eq("true")

        get active[:href]
        expect(response.body).to include("Open one")
      end

      it "prints short dates on the rows" do
        create(:idea, organization: org, project: project, updated_at: Time.zone.local(2026, 3, 12, 10))

        get member_ideas_path

        expect(html.find("[data-test='idea-last-activity-cell']")).to have_text(I18n.l(Date.new(2026, 3, 12), format: :day_month))
      end

      # CYRA-924 — cards or table is a View menu choice (C62); the bar holds no count (C63).
      it "switches between cards and table from the View menu, keeping the filters" do
        create(:idea, organization: org, project: project, title: "Card idea", votes_count: 3)

        get member_ideas_path(status: [ "open" ])
        menu = html.find("[data-test='ideas-toolbar-view-menu']")
        expect(menu).to have_css("[data-test='ideas-view-switch'] [data-test='ideas-view-table'][aria-current='true']", visible: :all)
        expect(menu.find("[data-test='ideas-view-cards']", visible: :all)[:href]).to include("status")
        expect(html.find("[data-test='ideas-toolbar']")).to have_no_text(I18n.t("member.ideas.count", count: 1))

        get member_ideas_path(view: "cards", status: [ "open" ])
        expect(html).to have_css("[data-test='idea-card']", text: "Card idea")
        expect(html).to have_no_css("[data-test='idea-row']")
      end

      it "shows no page counter under the empty list" do
        get member_ideas_path

        expect(html).to have_css("[data-test='ideas-empty']")
        expect(html).to have_no_css("[data-test='ideas-pagination']")
      end
    end

    describe "detail" do
      it "puts the problem first and the interest at the top of the right column" do
        sign_in(member)
        get member_idea_path(idea)

        main = html.find("[data-test='idea-main-column']")
        side = html.find("[data-test='idea-side-column']")
        expect(main).to have_css("[data-test='idea-problem']")
        expect(main).to have_no_css("[data-test='idea-interest']")
        expect(side).to have_css("[data-test='idea-interest']")
      end

      it "keeps the vote explainer behind an info tooltip" do
        sign_in(member)
        get member_idea_path(idea)

        interest = html.find("[data-test='idea-interest']")
        expect(interest).to have_css("[role='tooltip']", text: I18n.t("member.ideas.interest.explainer"), visible: :all)
        expect(interest).to have_no_css("p", text: I18n.t("member.ideas.interest.explainer"))
      end

      it "groups problem, solution, monetization and risks in one panel" do
        idea.update!(monetization: "Team plan.", risks: "Black and white print.")
        sign_in(member)
        get member_idea_path(idea)

        panel = html.find("[data-test='idea-content']")
        %w[idea-problem idea-solution idea-monetization idea-risks].each do |section|
          expect(panel).to have_css("[data-test='#{section}']")
        end
      end

      it "opens the use case form from a button" do
        sign_in(owner)
        get member_idea_path(idea)

        expect(html).to have_css("details[data-test='idea-case-form-toggle'] [data-test='member-idea-case-form']", visible: :all)
      end

      it "joins evolutions and related ideas in one Links panel" do
        sign_in(owner)
        get member_idea_path(idea)

        links = html.find("[data-test='idea-links']")
        expect(links).to have_css("[data-test='member-idea-evolutions']")
        expect(links).to have_css("[data-test='member-idea-related']")
      end

      it "keeps the conversion date when the ticket was deleted" do
        orphan = create(:idea, :converted, organization: org, project: project)
        orphan.ticket.destroy!
        sign_in(owner)
        get member_idea_path(orphan.reload)

        expect(html).to have_css("[data-test='idea-ticket'] [data-test='idea-converted-on']")
      end

      it "shows the status in the Details instead of a header chip" do
        sign_in(member)
        get member_idea_path(idea)

        expect(html).to have_css("[data-test='idea-details'] [data-test='idea-status']")
        expect(html).to have_no_css("[data-test='idea-counts']")
      end

      it "moves Archive into the more menu next to Delete" do
        sign_in(owner)
        get member_idea_path(idea)

        menu = "details:has([data-test='idea-menu-trigger'])"
        expect(html).to have_css("#{menu} [data-test='idea-archive']", visible: :all)
        expect(html).to have_css("#{menu} [data-test='idea-delete']", visible: :all)
      end
    end
  end
end
