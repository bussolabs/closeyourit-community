# frozen_string_literal: true

module Member
  module Knowledge
    # Knowledge base cross-progetto: pagine collegate a N progetti/gruppi visibili all'account (o
    # org-wide, viste solo da chi ha accesso pieno). Leggere e creare = baseline di chi vede lo scope;
    # gestire pagine ALTRUI è gated (knowledge.edit/delete, pattern Ideas/Books). Ricerca: toggle
    # semantico con fallback ILIKE (mai errori utente). Model SEMPRE fully-qualified ::Knowledge::*.
    class PagesController < Member::BaseController
      permission_not_required "Leggere, cercare e creare una pagina è baseline di chi vede lo scope; gestire le " \
                              "altrui è gated più sotto.",
                              only: %i[index show new create ask ask_query link_suggestions]

      include KnowledgePageManagement

      before_action :set_page, only: %i[show edit update destroy]
      before_action :require_manage_permission, only: %i[edit update destroy]
      before_action :load_form_options, only: %i[new create edit update]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :kind, :project_id, :tag, :author, :q, :sort, only: :index

      # CYRA-924 — every column sorts but Projects and Tags, which hold several values (C9). An
      # explicit sort wins over search relevance; without one, relevance keeps the order.
      SORT_COLUMNS = {
        "title" => "LOWER(knowledge_pages.title)",
        "kind" => :kind,
        "author" => "(SELECT LOWER(accounts.name) FROM accounts WHERE accounts.id = knowledge_pages.created_by_id)",
        "updated" => :updated_at
      }.freeze

      def index
        @pagination = filtered_pages
        @pages = @pagination.records
        # Chip di testata = quadro complessivo della KB (regola header: "totale + stati"), MAI i
        # risultati filtrati (CYRA-412 scenario 3). Restano così coerenti tra loro e con il messaggio
        # di zero risultati in ogni flusso: full-load con ?q oppure ricerca in-frame — l'header è fuori
        # dal turbo-frame knowledge-results e non si aggiorna via Turbo, quindi deve mostrare numeri
        # stabili. Un chip filtrato qui darebbe "0 pagine" contro un messaggio "ci sono 43 pagine".
        # Stesso pattern di Ideas (@status_counts sul totale visibile, non sulla query).
        @total_pages = visible.pages.count
        @decisions_count = visible.pages.kind_decision.count
        # CYRA-429: quante pagine aspettano una versione semplice. Il conteggio legge il verdetto già
        # scritto sulla riga, quindi è una WHERE su un booleano, non un'euristica su ogni corpo.
        @without_simple_count = visible.pages.without_simple_version.count
        # CYRA-419: quante pagine ha scritto un assistente. Come il chip qui sopra, legge una colonna
        # già scritta sulla riga — nessuna euristica in lettura.
        @written_by_agent_count = visible.pages.written_by_agent.count
        # CYRA-768: quante pagine hanno passato la data di rilettura. Il chip non toglie niente dalla
        # lista — la pagina scaduta resta cercabile, marcata (Scenario 2).
        @needs_review_count = visible.pages.needs_review.count
        # Distingue "KB vuota" (primo accesso) da "ricerca/filtri senza risultati": mai dire "vuota"
        # quando la lista è vuota solo perché una query o un filtro non ha prodotto match.
        @filtering = filtering?
        @query = search_q
        # Modalità dichiarata sopra i risultati (CYRA-417): true = per significato (default), false =
        # parole esatte. Stessa regola di searched() e del selettore nel toolbar → sempre allineati.
        @semantic_mode = semantic_search?
        @filter_projects = visible.projects.order(:name)
        @tag_options = ::Knowledge::Page.distinct_tags(visible.pages)
        # Anti-leak: nella lista mostro SOLO i progetti/gruppi visibili all'utente, non tutti quelli a
        # cui la pagina è collegata (una pagina è visibile con UN solo scope in comune). Set per filtrare
        # in memoria le associazioni già precaricate, senza N+1.
        @visible_project_ids = @filter_projects.map(&:id).to_set
        @visible_group_ids = visible.groups.pluck(:id).to_set
      end

      def show
        @can_edit = manageable?("knowledge.edit")
        @can_delete = manageable?("knowledge.delete")
        # Ultima versione (= live): autore dell'ultimo salvataggio per l'audit "aggiornato da".
        @last_version = @page.versions.last
        # Anti-leak: nel pannello scope mostro SOLO i progetti/gruppi che l'utente vede (come i book).
        @visible_projects = @page.projects.where(id: visible.projects.select(:id)).order(:name)
        @visible_groups = @page.groups.where(id: visible.groups.select(:id)).order(:name)
        # Set globale per etichettare i wikilink col primo progetto VISIBILE (non trapelare scope nascosti).
        @visible_project_ids = visible.projects.pluck(:id).to_set
        load_links
        # Book che contiene la pagina (al più uno: FK diretta book_id). Mostrato solo se il book è
        # visibile all'account (anti-leak, come i progetti): CYRA-415 Scenario 3, il legame pagina→book.
        @page_book = @page.book if @page.book_id && visible.books.exists?(@page.book_id)
      end

      def new
        # title arriva pre-compilato dal rimbalzo "crea con quel titolo" della ricerca a zero risultati (CYRA-412).
        @page = ::Knowledge::Page.new(kind: (params[:kind].presence || :note), title: params[:title].presence)
        @page.project = visible.projects.find_by(id: params[:project_id]) if params[:project_id].present?
      end

      def create
        # CYRA-419: qui scrive una persona, davanti a un modulo — è l'unico canale che può dirlo.
        result = ::Knowledge::CreatePage.call(
          organization: Current.organization, author: Current.account, params: page_params,
          authored_by: :human
        )
        if result.ok?
          warn_about_technical_language(result.value)
          redirect_to member_knowledge_page_path(result.value), notice: t("member.knowledge.created")
        else
          rebuild_page_for_form
          @errors = result.error.details || {}
          flash.now[:alert] = result.error.message
          # Lo status è quello dell'errore: un revisore giù (CYRA-764) è un 503, non un 422.
          render :new, status: result.error.status
        end
      end

      # Pagina RAG "chiedi alla KB" (read-only sulle pagine visibili: nessun gate oltre l'auth). Tre
      # blocchi di contesto attorno al campo (CYRA-421): lo scope su cui risponde, le domande d'esempio
      # dal contenuto reale, lo storico condiviso del team — tutti ristretti alla visibilità dell'utente.
      def ask
        @scope_projects = visible.projects.order(:name)
        @scope_pages_count = visible.pages.count
        @sample_questions = ask_sample_questions
        @ask_history = ask_history
        # Le citazioni salvate con una domanda possono includere pagine di progetti che il lettore non
        # vede (lo scope della domanda ha solo un progetto in comune col suo): mostrarne i titoli sarebbe
        # una fuga. Set delle sole pagine citate ancora visibili all'utente corrente → la view filtra.
        @ask_cited_page_ids = visible_cited_page_ids(@ask_history)
      end

      # Domanda in NL: accoda Ai::RunJob (kind knowledge_ask) e risponde 202 con request_id; la UI
      # polla l'esito su GET /member/ai/requests/:id. ASINCRONO come #compose (CYRA-275): una domanda
      # AI lenta non tiene più occupato un thread web per minuti. Lo scope visibile — full_access
      # (owner/god) oppure project/group ids — è AUTORIZZATO QUI (Current regge god/impersonation) e
      # passato al job, che si fida dell'autorizzazione fatta all'enqueue (Ai::RunJob#knowledge_ask_scope).
      def ask_query
        question = params[:question].to_s
        if question.strip.blank?
          return render json: { error: { code: "R422-KNOWLEDGE-003",
                                         message: t("member.knowledge.ask.errors.blank") } },
                        status: :unprocessable_content
        end

        enqueue_ai_request!(kind: "knowledge_ask", args: knowledge_ask_args(question))
      end

      # Titoli suggeriti mentre si apre un wikilink `[[…]]` nel corpo (CYRA-433). Lo scope è
      # visible.pages: un suggerimento non deve rivelare il titolo di una pagina che chi
      # scrive non potrebbe aprire. `exclude_id` è la pagina in modifica (non si cita da sola).
      # L'etichetta del tipo si traduce qui, non nel service: la lingua è del canale web.
      def link_suggestions
        pages = ::Knowledge::Links::Suggest.call(
          scope: visible.pages, organization: Current.organization,
          query: params[:q], exclude_id: params[:exclude_id]
        )
        render json: { data: pages.map { |page| { title: page.title, hint: t("member.knowledge.kind.#{page.kind}") } } }
      end

      def edit; end

      def update
        # authored_by: :human — se la modifica riscrive il testo (Knowledge::SubstantiveEdit) la
        # pagina diventa di chi l'ha riscritta e il segno «scritta da un assistente» decade.
        result = ::Knowledge::UpdatePage.call(page: @page, params: page_params, actor: Current.account,
                                              authored_by: :human)
        if result.ok?
          warn_about_technical_language(@page.reload)
          redirect_to member_knowledge_page_path(@page), notice: t("member.knowledge.updated")
        else
          @errors = result.error.details || {}
          flash.now[:alert] = result.error.message
          render :edit, status: result.error.status
        end
      end

      def destroy
        @page.destroy
        redirect_to member_knowledge_pages_path, notice: t("member.knowledge.deleted")
      end

      private

      # CYRA-429 — l'avviso sul linguaggio troppo tecnico arriva a chi ha appena scritto la pagina,
      # non a chi la legge: chi legge non può farci niente, chi scrive sì, e in quel momento ha il
      # testo davanti. Il verdetto è già congelato sulla pagina (Knowledge::Page#technical_body).
      def warn_about_technical_language(page)
        return unless page.simple_version_missing?

        flash[:warning] = t("member.knowledge.plain_warning_author")
      end

      # Anti-BOLA + scoping: pagina non visibile (nessun progetto/gruppo visibile, o org-wide per un
      # non-full-access) → RecordNotFound.
      # Il preload degli allegati col blob evita una coppia di query per riga nella card della show
      # (l'Attached::One risolve attachment e blob a runtime — stesso motivo per cui la index dei
      # documenti di progetto usa with_attached_file).
      def set_page
        @page = visible.pages.includes(attachments: { file_attachment: :blob }).find(params[:id])
      end

      # Regola condivisa col controller degli allegati: vedi KnowledgePageManagement.
      def manageable?(key)
        page_manageable?(@page, key)
      end

      def require_manage_permission
        key = action_name == "destroy" ? "knowledge.delete" : "knowledge.edit"
        return if manageable?(key)

        redirect_to root_path, alert: t("member.authorization.forbidden")
      end

      def load_form_options
        @projects = visible.projects.order(:name)
        @groups = visible.groups.order(:name)
      end

      # Ripopola i multi-select del form dopo un errore, senza toccare il DB (record in memoria).
      def rebuild_page_for_form
        @page = ::Knowledge::Page.new(
          title: page_params[:title], body: page_params[:body], tech_spec: page_params[:tech_spec],
          tags: page_params[:tags], kind: page_params[:kind].presence || :note,
          organization: Current.organization, created_by: Current.account
        )
        selected_project_ids = Array(page_params[:project_ids]).map(&:to_s)
        selected_group_ids = Array(page_params[:group_ids]).map(&:to_s)
        @page.projects = @projects.select { |project| selected_project_ids.include?(project.id.to_s) }
        @page.groups = @groups.select { |group| selected_group_ids.include?(group.id.to_s) }
      end

      # Collegamenti in uscita ("Collegate") e in entrata ("Citata da"), SEMPRE ristretti alle pagine
      # visibili: una pagina può citarne una non visibile, e quel titolo non deve trapelare.
      def load_links
        @links = @page.links.where(related_id: visible.pages.select(:id)).includes(related: :projects)
        @backlinks = @page.inverse_links.where(page_id: visible.pages.select(:id)).includes(page: :projects)
      end

      def filtered_pages
        scope = visible.pages.includes(:projects, :groups, :created_by).ordered
        scope = pages_for_projects(scope, filter_ids(:project_id)) if filter_ids(:project_id).any?
        scope = scope.where(kind: filter_ids(:kind)) if filter_ids(:kind).any?
        scope = scope.tagged_any(filter_ids(:tag)) if filter_ids(:tag).any?
        # CYRA-419: «Scritta da» — isolare le pagine scritte da un assistente senza aprirle una a una.
        scope = scope.written_by(filter_ids(:author)) if filter_ids(:author).any?
        paginate(sorted(searched(scope), columns: SORT_COLUMNS))
      end

      # Una ricerca testuale o un filtro è attivo: la lista vuota va spiegata come "nessun risultato",
      # non come knowledge base vuota (CYRA-412).
      def filtering?
        search_q.present? || filter_ids(:kind).any? || filter_ids(:project_id).any? ||
          filter_ids(:tag).any? || filter_ids(:author).any?
      end

      # Filtro progetto N:N: la pagina matcha se un progetto selezionato è tra i diretti O nei gruppi.
      # La regola vive sul model (Knowledge::Page.for_projects) perché la usa anche la coda di
      # revisione (CYRA-560): due filtri «progetto» che rispondono in modo diverso sarebbero un bug.
      def pages_for_projects(scope, ids)
        scope.for_projects(ids)
      end

      # Ramo ricerca: per significato (default, ordinata per pertinenza) o «parole esatte» (semantic=0)
      # scelto dall'utente col selettore di modalità. La promessa era «capisce il significato»: la
      # modalità predefinita ora la mantiene (CYRA-417), invece di trovare solo le parole identiche.
      # Servizio embedding giù → fallback ILIKE + hint muto (@semantic_degraded): MAI errori utente.
      # L'algoritmo (semantico + coda testuale) vive in Knowledge::HybridSearch, condiviso con la
      # CLI: qui resta solo come lo si racconta a video (CYRA-769).
      def searched(scope)
        outcome = ::Knowledge::HybridSearch.call(scope: scope, query: search_q, semantic: semantic_search?)
        @semantic_degraded = semantic_search? && outcome.mode == :like
        outcome.scope
      end

      # Modalità di ricerca: "0" esplicito = parole esatte; assente o "1" = per significato (default).
      # Unico punto di verità per searched, @semantic_mode (banner) e il selettore nel toolbar.
      def semantic_search?
        params[:semantic] != "0"
      end

      # Scope e tag inclusi SOLO se il canale li invia (un update parziale non li azzera). Il form web
      # li manda sempre (multi-select con hidden), così deselezionare tutto rende la pagina org-wide.
      # tag come testo separato da virgole (il model normalizza strip/downcase/uniq).
      def page_params
        attrs = { title: params[:title], body: params[:body], tech_spec: params[:tech_spec], kind: params[:kind] }
        attrs[:project_ids] = Array(params[:project_ids]).reject(&:blank?) if params.key?(:project_ids)
        attrs[:group_ids] = Array(params[:group_ids]).reject(&:blank?) if params.key?(:group_ids)
        attrs[:tags] = params[:tags].to_s.split(",") if params.key?(:tags)
        attrs
      end

      # Payload minimale per le citazioni dell'ask.
      # Gemello server-side di visible.pages, calcolato dove Current.true_account regge god/
      # impersonation e passato al job (che non ha Current): owner/god vedono tutte le pagine dell'org
      # (full_access), gli altri solo quelle su un progetto/gruppo visibile. La serializzazione delle
      # citazioni vive ora in Ai::RunJob#page_ask_payload (l'esito è reso dal poll, non da qui).
      #
      # Dal CYRA-812 l'ELENCO viaggia anche per chi ha accesso pieno: quel perimetro è il tetto della
      # domanda, e il job lo interseca con il perimetro di allora invece di fidarsene e basta.
      def knowledge_ask_args(question)
        { question: }.merge(ai_scope_args)
      end

      # Accesso pieno alla KB dell'org = owner/god (Current regge god/impersonation). Unico punto di
      # verità per lo scope della domanda, dello storico e delle domande d'esempio.
      def ask_full_access?
        visible.unscoped?
      end

      # Domande d'esempio (CYRA-421): i semi seminati ogni notte per i progetti visibili. Finché il giro
      # notturno non ne ha ancora prodotti (KB appena popolata), fallback in memoria dalle pagine
      # visibili più recenti — stesso contenuto reale, non persistito — così la schermata non nasce vuota.
      def ask_sample_questions
        persisted = ::Knowledge::SampleQuestion.for_projects(visible.projects.select(:id))
                                               .ordered.limit(::Knowledge::Constants::SAMPLE_QUESTIONS_SHOWN).to_a
        return persisted if persisted.any?

        visible.pages.ordered.limit(::Knowledge::Constants::SAMPLE_QUESTIONS_SHOWN).map do |page|
          ::Knowledge::SampleQuestion.new(title: page.title, kind: page.kind)
        end
      end

      # Storico condiviso del team, ristretto alla STESSA visibilità delle pagine (visible_to): le più
      # recenti senza ripetere lo stesso testo. Dedup in Ruby su una finestra un po' più larga della resa.
      def ask_history
        ::Knowledge::AskLog.visible_to(
          account: Current.account, organization: Current.organization, full_access: ask_full_access?,
          visible_project_ids: visible.projects.pluck(:id), visible_group_ids: visible.groups.pluck(:id)
        ).recent.limit(30).to_a.uniq { |log| log.question.strip.downcase }
                 .first(::Knowledge::Constants::ASK_HISTORY_SHOWN)
      end

      # Id (stringa) delle pagine citate dallo storico che l'utente PUÒ ancora vedere: la view mostra
      # solo queste citazioni. Una sola query batch su tutte le citazioni, mai per riga (no N+1).
      def visible_cited_page_ids(history)
        ids = history.flat_map { |log| Array(log.citations).filter_map { |citation| citation["id"] } }.uniq
        return Set.new if ids.empty?

        visible.pages.where(id: ids).pluck(:id).map(&:to_s).to_set
      end
    end
  end
end
