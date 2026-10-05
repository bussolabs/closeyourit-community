# frozen_string_literal: true

module Member
  module Knowledge
    # Coda di revisione delle pagine KB (CYRA-298): le proposte scritte da un assistente aspettano
    # qui che un umano le accetti o le scarti. Finché aspettano restano fuori da ricerca, risposte,
    # correlate e liste — vedi Knowledge::Page.visible_to.
    #
    # La pagina mostra anche le accettate che non sono ancora state scritte fra i documenti
    # versionati: accettare è la decisione, archiviare è il passo che chiude il flusso.
    #
    # Model SEMPRE fully-qualified ::Knowledge::* (anti-shadowing, come gli altri controller
    # dell'area). Leggere la coda = baseline di chi vede lo scope; decidere è gated dal service
    # (Knowledge::PageManageable, chiave knowledge.edit).
    class ReviewsController < Member::BaseController
      permission_not_required "Leggere la coda è baseline di chi vede lo scope; accettare o scartare lo autorizza il " \
                              "service (knowledge.edit)."

      before_action :set_page, only: %i[approve reject]
      # CYRA-768: confermare bersaglia una pagina PUBBLICATA, non una proposta — un lookup a parte.
      before_action :set_published_page, only: :confirm

      # CYRA-817 — il riquadro delle accettate da archiviare si aggiorna per conto suo: sfogliarlo o
      # cercarci dentro chiede al server SOLO lui, e coda, rilettura e scarti non si ricalcolano.
      TO_FILE_FRAME = "knowledge-review-to-file"

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :project_id, :q, :to_file_q, only: :index

      # CYRA-924 — the three lists sort on their columns (C9). The two short ones show the most
      # urgent pages first and sort only what they show; the accepted ones page, so they sort in SQL.
      TITLE = ->(page) { page.title.to_s.downcase }
      NEEDS_REVIEW_SORT_COLUMNS = { "page" => TITLE, "review_after" => ->(page) { page.review_after } }.freeze
      REJECTED_SORT_COLUMNS = { "page" => TITLE, "rejected" => ->(page) { page.reviewed_at },
                                "by" => ->(page) { page.reviewed_by&.name&.downcase } }.freeze
      TO_FILE_SORT_COLUMNS = { "page" => "LOWER(knowledge_pages.title)",
                               "accepted" => "COALESCE(knowledge_pages.reviewed_at, knowledge_pages.updated_at)" }.freeze

      def index
        # CYRA-817 — le accettate da archiviare per prime: quando la richiesta arriva dal loro
        # riquadro sono l'unica cosa da calcolare, e il resto della pagina non si tocca.
        @to_file_pagination = paginate(sorted(filtered_to_file, columns: TO_FILE_SORT_COLUMNS, param: :to_file_sort),
                                       :to_file_page, per_param: :to_file_per)
        @to_file = @to_file_pagination.records
        # Il totale è un conteggio, non la lunghezza di ciò che si è caricato: il chip dice quante
        # aspettano davvero anche quando in pagina se ne leggono dieci. Fuori dalla ricerca, come il
        # chip della coda: è il quadro complessivo, mai il risultato filtrato.
        @to_file_total = pages_awaiting_consolidation.count
        # Distingue «non c'è niente da archiviare» da «la ricerca non ha trovato».
        @to_file_filtering = to_file_q.present?
        return render partial: "member/knowledge/reviews/to_file_section", layout: false if to_file_frame?

        # CYRA-560 — la coda si riempie da sola e nessuno la svuota: era arrivata a centosessantasette
        # proposte in un blocco unico, quasi cinquanta schermate. Ora è una lista come le altre —
        # divisa in pagine, con ricerca e filtro progetto — e il totale della coda resta nel chip in
        # alto (quadro complessivo, MAI il risultato filtrato: stessa regola dell'index delle pagine).
        @waiting_total = visible.pages_in_review.count
        @demoted_total = visible.pages_in_review.ai_review_rejected.count
        @pagination = paginate(filtered_waiting)
        @waiting = @pagination.records
        # Distingue «la coda è vuota» da «la ricerca non ha trovato»: mai dire vuota con 167 in attesa.
        @filtering = filtering?
        @filter_projects = visible.projects.order(:name)
        @expanded_bodies = EXPANDED_BODIES
        @rejected = sorted_rows(rejected_pages.includes(:projects, :reviewed_by).order(reviewed_at: :desc).limit(REJECTED_SHOWN).to_a,
                                columns: REJECTED_SORT_COLUMNS, param: :rejected_sort)
        @rejected_total = rejected_pages.count
        # CYRA-768 — le pagine oltre la data di rilettura. Sono già visibili a tutti: qui non
        # aspettano il permesso di entrare, aspettano che qualcuno confermi che sono ancora vere.
        # Dalla più scaduta, e non tutte: una coda lunga si legge dalla cima, il totale sta nel chip.
        @needs_review = sorted_rows(visible.pages.needs_review.includes(:projects).order(:review_after).limit(NEEDS_REVIEW_SHOWN).to_a,
                                    columns: NEEDS_REVIEW_SORT_COLUMNS, param: :needs_review_sort)
        @needs_review_total = visible.pages.needs_review.count
      end

      def approve
        decide(::Knowledge::Pages::Approve.call(page: @page, actor: Current.account), :approved)
      end

      def reject
        decide(::Knowledge::Pages::Reject.call(page: @page, actor: Current.account), :rejected)
      end

      # CYRA-768 — «è ancora vera»: il conto riparte, il testo non si tocca. Il guard umano sta nel
      # service, come per accetta e scarta.
      def confirm
        decide(::Knowledge::Pages::ConfirmReview.call(page: @page, actor: Current.account), :confirmed)
      end

      private

      # Le scartate servono a non farsi riproporre la stessa nota, non a essere sfogliate: se ne
      # mostrano le ultime, col totale accanto.
      REJECTED_SHOWN = 10

      # Quante pagine da rileggere si mostrano: la coda della rilettura è una sezione della pagina,
      # non la pagina — il totale sta nel chip in alto e non mente mai.
      NEEDS_REVIEW_SHOWN = 20

      # CYRA-425 — il testo da giudicare sta aperto, non chiuso sotto i bottoni: chi decide deve
      # averlo davanti. Aprirle TUTTE però farebbe una pagina lunghissima quando la coda cresce,
      # quindi si aprono le prime della fila e le altre restano a un clic.
      EXPANDED_BODIES = 3

      # Anti-BOLA: la proposta si risolve tra quelle visibili all'account (fuori scope → 404).
      def set_page
        @page = visible.pages_in_review.find(params[:id])
      end

      # Anti-BOLA: la pagina da confermare si risolve fra le PUBBLICATE visibili (fuori scope → 404).
      def set_published_page
        @page = visible.pages.find(params[:id])
      end

      def rejected_pages
        visible.pages(status: :rejected)
      end

      # Coda filtrata: ricerca sul titolo (ILIKE, come i book — qui si cerca una proposta che si sa
      # di aver visto, non un concetto) e filtro progetto N:N (diretto o via gruppo).
      def filtered_waiting
        scope = visible.pages_in_review.includes(:projects, :created_by).order(created_at: :desc)
        scope = scope.for_projects(filter_ids(:project_id)) if filter_ids(:project_id).any?
        scope = scope.where("knowledge_pages.title ILIKE ?", "%#{search_q}%") if search_q.present?
        scope
      end

      def filtering? = search_q.present? || filter_ids(:project_id).any?

      # Le accettate che nessuno ha ancora scritto fra i documenti versionati.
      def pages_awaiting_consolidation = visible.pages.awaiting_consolidation

      # CYRA-817 — la ricerca del riquadro ha un parametro SUO: `q` è dichiarato in pagina come
      # ricerca «fra le proposte in attesa», e scriverci dentro da qui ne cambierebbe il significato
      # senza dirlo — filtrando per giunta una coda che chi cerca qui non sta guardando.
      def to_file_q = params[:to_file_q].to_s.strip

      def filtered_to_file
        scope = pages_awaiting_consolidation.includes(:projects)
                                            .order(reviewed_at: :desc, updated_at: :desc)
        return scope if to_file_q.blank?

        scope.where("knowledge_pages.title ILIKE ?", "%#{to_file_q}%")
      end

      # La richiesta arriva dal riquadro delle accettate (l'intestazione la mette Turbo)?
      def to_file_frame? = turbo_frame_request_id == TO_FILE_FRAME

      # CYRA-560 Scenario 2 — la decisione torna ESATTAMENTE alla lista da cui è partita: pagina,
      # ricerca, filtro e densità viaggiano con il bottone. Senza, accettare la trentesima proposta
      # riportava alla prima pagina della coda intera, e ricominciava lo scorrimento. Stesso URL =
      # per Turbo è un page refresh, quindi morph + scroll conservato (vedi la vista).
      # filter_ids normalizza il progetto (scalare o array) come lo legge la lista: se il redirect
      # leggesse i param in un modo diverso da chi filtra, un filtro scritto a mano nell'indirizzo
      # sopravvivrebbe alla lista ma non alla decisione.
      def list_params
        { page: params[:page], per: params[:per], q: search_q.presence,
          project_id: filter_ids(:project_id) }.compact_blank
      end

      def decide(result, notice_key)
        if result.ok?
          redirect_to member_knowledge_reviews_path(list_params), notice: t("member.knowledge.reviews.#{notice_key}")
        else
          redirect_to member_knowledge_reviews_path(list_params), alert: result.error.message
        end
      end
    end
  end
end
