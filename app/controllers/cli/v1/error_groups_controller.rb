# frozen_string_literal: true

module Cli
  module V1
    # Gruppi d'errore del progetto (lettura). La visibilità del progetto È il gate (no permesso-chiave).
    # Progetto fuori scope → R404 (set_project! → anti-BOLA).
    class ErrorGroupsController < Cli::V1::BaseController
      before_action :set_project!
      # CYRA-45: il triage bulk muta lo stato → gate errors.triage sul progetto (come resolution/mute).
      # CYRA-192: resolution/merge/destroy mutano allo stesso modo → stesso gate.
      before_action -> { require_permission!("errors.triage", scope: @project) }, only: :bulk_triage
      # CYRA-192: fondere ed eliminare distruggono dati e non si annullano → chiave PROPRIA, non
      # errors.triage (che il ruolo "Triager" ha già, e che serve a smistare, non a cancellare).
      # CYRA-153: split è una manipolazione strutturale del grouping come merge → stessa chiave.
      before_action -> { require_permission!("errors.destroy", scope: @project) }, only: %i[merge split destroy]
      # CYRA-153: assegnare ha la sua chiave (reversibile, non distrugge dati) — non errors.destroy.
      before_action -> { require_permission!("errors.assign", scope: @project) }, only: :assign

      def index
        # CYRA-738 — stessa domanda ai dati del canale API (Errors::Groups::Query).
        records, meta = paginate(::Errors::Groups::Query.call(project: @project, status: params[:status]))
        render_ok(ErrorGroupSerializer.new(records), meta: meta)
      end

      def show
        group = @project.error_groups.find(params[:id])
        render_ok(ErrorGroupSerializer.new(group))
      end

      # CYRA-45: triage bulk (ids[] + bulk_action resolve/ignore/reopen) — equivalente CLI del bottone
      # bulk della lista Member. Scope = @project.error_groups (già gattato): id fuori progetto scartati.
      # `bulk_action`, non `action` (riservato da Rails). Ritorna i gruppi toccati + meta.updated.
      def bulk_triage
        result = Errors::BulkTriage.call(
          scope: @project.error_groups, ids: params[:ids], action: params[:bulk_action]
        )
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

        render_ok(ErrorGroupSerializer.new(result.value), meta: { updated: result.value.size })
      end

      # Fonde N gruppi in questo (`ids` = quelli da assorbire). IRREVERSIBILE: le occorrenze passano
      # qui e i gruppi assorbiti spariscono. Gli id vanno al service GREZZI: è lui a risolverli tutti
      # o nessuno — filtrarli qui fonderebbe quelli validi ignorando gli altri in silenzio, e su
      # un'operazione che non si annulla è la cosa peggiore.
      def merge
        primary = @project.error_groups.find(params[:id])
        result = Errors::Merge.call(primary:, source_ids: params[:ids])
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

        # Contato dal risultato, non dagli id in ingresso: il primario eventualmente passato fra le
        # sorgenti è già stato escluso, e riportarlo gonfierebbe il conteggio.
        render_ok(ErrorGroupSerializer.new(result.value),
                  meta: { merged: (Array(params[:ids]).map(&:to_s).uniq - [ primary.id.to_s ]).size })
      end

      # Elimina il gruppo e le sue occorrenze (`dependent: :destroy`). Nessun vincolo di stato: chi ha
      # il permesso sa cosa sta cancellando, e imporre "prima risolvilo" non proteggerebbe da nulla.
      def destroy
        group = @project.error_groups.find(params[:id])
        group.destroy!
        render_ok({ id: group.id, deleted: true })
      end

      # CYRA-153: divide il gruppo estraendo le occorrenze `event_ids` in un nuovo gruppo. Gli id
      # vanno al service grezzi: è lui a risolverli tutti-o-niente (come per il merge). Ritorna il
      # NUOVO gruppo creato.
      def split
        group = @project.error_groups.find(params[:id])
        result = Errors::Split.call(group:, event_ids: params[:event_ids])
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

        render_ok(ErrorGroupSerializer.new(result.value))
      end

      # CYRA-153: assegna/disassegna l'errore (assignee_id vuoto = disassegna). Il service filtra
      # l'assignee sull'org (anti-BOLA): un id fuori org lascia il gruppo non assegnato.
      def assign
        group = @project.error_groups.find(params[:id])
        result = Errors::Assign.call(group:, assignee_id: params[:assignee_id])
        render_ok(ErrorGroupSerializer.new(result.value))
      end
    end
  end
end
