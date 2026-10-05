# frozen_string_literal: true

module Cli
  module V1
    module Knowledge
      # Knowledge base per la CLI (`cyi kb`): pagine visibili all'account del token (collegate a N
      # progetti/gruppi, o org-wide per chi ha accesso pieno). Leggere/creare = baseline dello scope;
      # gestire pagine ALTRUI è gated knowledge.edit/delete su TUTTI i progetti effettivi (l'autore
      # gestisce sempre le proprie, pattern Ideas/Books). Logica nei service Knowledge::* condivisi.
      class PagesController < Cli::V1::BaseController
        # Su una LISTA i correlati si calcolano in una passata batchata e solo per le prime righe,
        # con pochi collegamenti ciascuna. Chi ne vuole di più (o li vuole semantici) usa `kb related`.
        RELATED_FOR_RESULTS = 10
        RELATED_PER_RESULT = 3
        # Valori ammessi da ?status=. "all" = nessun filtro (chi vuole vedere tutto insieme).
        STATUS_FILTERS = %w[published in_review rejected all].freeze

        before_action :set_page, only: %i[show update destroy related approve reject consolidated]

        # ?q= → ricerca SEMANTICA con fallback ILIKE automatico. Filtri: kind[], project (key o UUID),
        # status (default: solo le pubblicate), awaiting_consolidation, needs_review.
        def index
          status = status_filter
          return render_error("R422-KNOWLEDGE-011", I18n.t("member.knowledge.errors.status_invalid"), status: :unprocessable_content) if status == :invalid

          scope = visible_pages(status: status).includes(:projects, :groups, :created_by).ordered
          scope = scope.awaiting_consolidation if awaiting_consolidation?
          # CYRA-768 — le pagine oltre la data di rilettura. Solo un FILTRO: confermare che una
          # pagina è ancora vera è un giudizio, e lo dà una persona dalla coda di revisione — un
          # token si autoconfermerebbe le proprie pagine e la scadenza non varrebbe niente.
          scope = scope.needs_review if needs_review?
          scope = scope.where(kind: kind_filter) if kind_filter.any?
          if params[:project].present?
            project = resolve_project(params[:project])
            return render_error("R404-KNOWLEDGE-001", I18n.t("member.knowledge.errors.project_not_found"), status: :not_found) if project.nil?

            scope = pages_for_project(scope, project)
          end
          scope = searched(scope)
          records, meta = paginate(scope)
          meta[:search] = @search_mode if @search_mode
          meta[:related] = related_by_page(records) if related_requested?
          render_ok(serialize_pages(records), meta: meta)
        end

        def show
          meta = { related: serialize_related(related_for(@page)) } if related_requested?
          render_ok(serialize_pages(@page), meta: meta)
        end

        # Pagine da leggere dopo questa: collegate a mano (wikilink, in entrata e in uscita) e
        # vicine per significato. Con `?question=` restano solo quelle inerenti alla domanda.
        def related
          rows = related_for(@page)
          render_ok(KnowledgeRelatedPageSerializer.new(rows, params: visible_scope_params),
                    meta: { question: related_question.presence, links_only: links_only? })
        end

        def create
          # project_ids diretti dal payload (multi-progetto) UNITI al ref CLI-friendly `project`
          # (key/UUID): passare solo `project` non deve azzerare i project_ids inviati, e viceversa.
          ids = Array(page_params[:project_ids]).map(&:to_s).reject(&:blank?)
          if (ref = params[:project].presence || params[:project_id].presence)
            project = resolve_project(ref)
            return render_error("R404-KNOWLEDGE-001", I18n.t("member.knowledge.errors.project_not_found"), status: :not_found) if project.nil?

            ids |= [ project.id ]
          end

          result = ::Knowledge::CreatePage.call(
            organization: Current.organization, author: Current.account,
            params: page_params.merge(project_ids: ids),
            authored_by: authored_by, author_origin: author_origin
          )
          if result.ok?
            render_created(serialize_pages(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def update
          return unless authored_or_permitted!("knowledge.edit")

          result = ::Knowledge::UpdatePage.call(page: @page, params: page_params, actor: Current.account,
                                                authored_by: authored_by, author_origin: author_origin)
          if result.ok?
            render_ok(serialize_pages(@page))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          return unless authored_or_permitted!("knowledge.delete")

          @page.destroy
          render_no_content
        end

        # Primo passo della revisione (CYRA-642): la proposta entra nella conoscenza. Il gate di
        # canale è quello di update/destroy (vede tutto lo scope + autore o `knowledge.edit`); che a
        # decidere debba essere una PERSONA lo impone il service, non qui — la regola vale anche per
        # il web e un guard duplicato nel controller sarebbe il posto da cui domani sparisce.
        def approve
          decide(::Knowledge::Pages::Approve)
        end

        # Speculare ad approve: la proposta resta archiviata come scartata, fuori da ricerca, RAG,
        # correlate e liste. Non si cancella niente — vedi Knowledge::Pages::Reject.
        def reject
          decide(::Knowledge::Pages::Reject)
        end

        # Terzo passo della revisione (CYRA-298): la pagina accettata è stata scritta anche come
        # documento versionato nel repo della knowledge base. Questo passaggio è meccanico e lo
        # chiude la stessa automazione che archivia il file.
        def consolidated
          return unless authored_or_permitted!("knowledge.edit")

          result = ::Knowledge::Pages::MarkConsolidated.call(
            page: @page, actor: Current.account, source_path: params[:source_path]
          )
          if result.ok?
            render_ok(serialize_pages(@page.reload))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        # RAG "chiedi alla KB" sulle pagine visibili: {answer, insufficient, pages (citazioni),
        # related (secondo salto)}.
        def ask
          question = params[:question].to_s
          result = ::Knowledge::AskPages.call(scope: visible_pages, question: question,
                                              organization: Current.organization)
          if result.ok?
            answer = result.value
            render json: { data: { answer: answer.answer, insufficient: answer.insufficient,
                                   pages: serialize_pages(answer.pages).as_json,
                                   related: serialize_related(second_hop(answer.pages, question)) } }
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
        end

        # CYRA-767 — pacchetto di contesto di un progetto: l'elenco corto delle sue pagine, una riga
        # di riassunto ciascuna. È una LETTURA dentro lo scope già visibile al token, quindi nessuna
        # chiave di permesso in più: chi vede il progetto vede le sue pagine, esattamente come
        # nell'elenco. Il progetto è obbligatorio — un pacchetto di contesto "di tutto" sarebbe la
        # lista pagine, che esiste già.
        def context
          ref = params[:project].to_s.strip
          if ref.blank?
            return render_error("R422-KNOWLEDGE-014", I18n.t("member.knowledge.errors.project_required"),
                                status: :unprocessable_content)
          end

          project = resolve_project(ref)
          return render_error("R404-KNOWLEDGE-001", I18n.t("member.knowledge.errors.project_not_found"), status: :not_found) if project.nil?

          service = ::Knowledge::ProjectContext.new(project: project, scope: visible_pages, limit: params[:limit])
          rows = service.call
          render_ok(KnowledgeContextPageSerializer.new(rows),
                    meta: { project: project.key, limit: service.limit, total: rows.size })
        end

        private

        # Accettare e scartare condividono gate, forma della risposta e resa degli errori: cambia
        # solo il service. La pagina si ricarica sempre (lo stato è appena cambiato).
        def decide(service)
          return unless authored_or_permitted!("knowledge.edit")

          result = service.call(page: @page, actor: Current.account)
          if result.ok?
            render_ok(serialize_pages(@page.reload))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        # Anti-BOLA: pagina risolta tra quelle visibili all'account (fuori scope → R404). status: nil
        # di proposito: la CLI è il canale di chi PROPONE e deve poter rileggere per id la bozza
        # appena creata (e consolidarla). Il filtro di stato protegge ricerca, RAG e liste, non la
        # show di una pagina di cui si conosce già l'id e che si potrebbe comunque vedere.
        def set_page
          @page = visible_pages(status: nil).find(params[:id])
        end

        def visible_pages(status: :published)
          ::Knowledge::Page.visible_to(account: Current.account, organization: Current.organization,
                                       visible_project_ids: visible_projects.select(:id),
                                       visible_group_ids: visible_groups.select(:id),
                                       status: status)
        end

        # ?status= → :published (default), :in_review, :rejected, oppure nil per "all". Un valore
        # non riconosciuto è un errore e non un default silenzioso: un filtro ignorato qui farebbe
        # credere che la coda di revisione sia vuota.
        def status_filter
          raw = params[:status].to_s.strip
          return :published if raw.blank?
          return :invalid unless STATUS_FILTERS.include?(raw)

          raw == "all" ? nil : raw.to_sym
        end

        def awaiting_consolidation? = params[:awaiting_consolidation].present?

        def needs_review? = params[:needs_review].present?

        # Filtro CLI per UN progetto: pagine col progetto tra i diretti O in un gruppo collegato.
        def pages_for_project(scope, project)
          scope.where(
            "EXISTS (SELECT 1 FROM connections_page_projects pp WHERE pp.page_id = knowledge_pages.id AND pp.project_id = ?) " \
            "OR EXISTS (SELECT 1 FROM connections_page_groups pg WHERE pg.page_id = knowledge_pages.id AND pg.group_id = ?)",
            project.id, project.group_id
          )
        end

        # Riferimento progetto CLI-friendly: key umana ("DRRA", case-insensitive) o UUID.
        def resolve_project(ref)
          ref = ref.to_s.strip
          return nil if ref.blank?

          visible_projects.find_by(key: ref.upcase) || visible_projects.find_by(id: ref)
        end

        def kind_filter
          Array(params[:kind]).reject(&:blank?) & ::Knowledge::Page.kinds.keys
        end

        # Significato + parole esatte, la stessa ricerca dell'elenco a video (CYRA-769): un canale
        # che rispondesse in modo diverso sullo stesso archivio e con la stessa parola sarebbe un
        # bug. Degrado silenzioso a servizio embedding giù, mai errori. La scope arriva già filtrata
        # per stato: cercare fra le proposte non allarga i permessi, li eredita.
        def searched(scope)
          outcome = ::Knowledge::HybridSearch.call(scope: scope, query: params[:q])
          @search_mode = outcome.mode&.to_s
          outcome.scope
        end

        # Gestione allineata al canale Member: serve SEMPRE vedere l'intero scope della pagina
        # (full_scope_access) — anche l'autore, altrimenti via CLI potrebbe toccare una pagina
        # collegata a progetti che non vede più. Poi: autore, oppure permesso su TUTTI i progetti
        # effettivi (org-wide, nessuno scope → solo full-access).
        def authored_or_permitted!(key)
          unless full_scope_access?
            render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
            return false
          end
          return true if @page.authored_by?(Current.account)

          projects = @page.effective_projects.to_a
          allowed = projects.empty? ? full_access? : projects.all? { |project| authorization.can?(key, scope: project) }
          return true if allowed

          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          false
        end

        # Vede TUTTI i progetti effettivi della pagina (gemello di Member::Knowledge::Pages#full_scope_access?).
        def full_scope_access?
          !@page.effective_projects.where.not(id: visible_projects.select(:id)).exists?
        end

        def full_access?
          Authorization::VisibleScope.unscoped?(account: Current.account, organization: Current.organization)
        end

        # Tag opzionali (array). Il progetto/gruppo si passano a parte (project_ids) da create/update.
        def page_params
          params.permit(:title, :body, :tech_spec, :kind, :in_review, :review_note,
                        tags: [], project_ids: [], group_ids: [])
        end

        # CYRA-419 — chi ha scritto il testo, che NON è l'account del token. Lo dichiara il
        # chiamante con `author_origin` (nome dell'assistente o della skill che sta scrivendo).
        # Senza dichiarazione, una proposta in revisione è per costruzione la proposta di un
        # assistente — nessuna persona chiede la revisione di quello che ha appena scritto a mano —
        # ed è etichettata col canale usato, cioè il nome del token. Tutto il resto resta di origine
        # NON REGISTRATA: attribuirlo a una persona per difetto è la firma sbagliata che questo
        # ticket toglie.
        def authored_by = agent_authored? ? :agent : nil

        def author_origin
          return nil unless agent_authored?

          declared_origin || Current.api_token&.name
        end

        def agent_authored? = declared_origin.present? || review_requested?

        def declared_origin = params[:author_origin].presence

        def review_requested? = ActiveModel::Type::Boolean.new.cast(params[:in_review]).present?

        # I correlati sono OPT-IN (`?related=1`, implicito con una domanda): senza, il costo è quello di sempre.
        def related_requested?
          params[:related].present? || params[:question].present?
        end

        def links_only? = params[:links_only].present?

        def related_question = params[:question].to_s

        def related_for(page, limit: ::Knowledge::RelatedPages::TOP_K)
          ::Knowledge::RelatedPages.call(pages: page, scope: related_scope, question: related_question,
                                         links_only: links_only?, limit: limit)
        end

        def related_by_page(records)
          ::Knowledge::RelatedPages.call(
            pages: records.first(RELATED_FOR_RESULTS), scope: related_scope,
            question: related_question.presence || params[:q], grouped: true, limit: RELATED_PER_RESULT
          ).transform_values { |rows| serialize_related(rows) }
        end

        def second_hop(cited, question)
          return [] if cited.blank?

          ::Knowledge::RelatedPages.call(pages: cited, scope: related_scope, question: question)
        end

        def related_scope
          visible_pages.includes(:projects)
        end

        def serialize_related(rows)
          KnowledgeRelatedPageSerializer.new(rows, params: visible_scope_params).as_json
        end

        def serialize_pages(records)
          KnowledgePageSerializer.new(records, params: visible_scope_params)
        end

        # Set dei progetti/gruppi visibili: il serializer li usa per non enumerare scope non visibili
        # (anti-leak). Memoizzato per richiesta (una pluck sola per lista/show).
        def visible_scope_params
          @visible_scope_params ||= {
            visible_project_ids: visible_projects.pluck(:id).to_set,
            visible_group_ids: visible_groups.pluck(:id).to_set
          }
        end
      end
    end
  end
end
