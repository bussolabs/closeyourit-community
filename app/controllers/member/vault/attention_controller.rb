# frozen_string_literal: true

module Member
  module Vault
    # Pagina «Da sistemare» (CYRA-428): un posto solo per ciò che sui segreti richiede un'azione.
    # Prende il posto di «Cosa non torna», «Rotazione» e «Modifiche ai segreti» — tre voci di menu
    # che rispondevano tutte alla stessa domanda, di cui due quasi sempre vuote. Le tre pagine
    # restano raggiungibili dai loro indirizzi, che ora portano qui (redirect).
    #
    # Il gate è la SOMMA dei gate di prima, non un gate nuovo: chi ha secrets_audit.view vede anomalie
    # e rotazioni, chi supera vault_change_requests_nav_visible? vede le richieste, chi ha entrambi
    # vede tutto. Nessuno vede più di quanto vedeva quando le pagine erano tre.
    #
    # index OSSERVA e PERSISTE come faceva HealthController: Secrets::Health::RecordAnomalies aggiorna
    # la memoria delle anomalie (first_seen_at + resolve delle sparite) alla visita. Scrittura dentro
    # una GET voluta e documentata — è l'unico punto di osservazione, non esiste un ingest.
    class AttentionController < Member::BaseController
      before_action :require_attention_view
      helper_method :surveillance?

      def index
        projects = visible.projects.to_a
        @project_options = projects.sort_by(&:name).map { |project| [ project.name, project.id ] }
        load_surveillance(projects) if surveillance?
        @pending = ::Secrets::ChangeRequests::Pending.new(account: Current.account, projects: projects) if change_requests?
        # CYRA-777 — le proposte di «valore in comune» sono org-scoped e non passano da
        # visible.projects: nascono dal confronto fra progetti, e chi ne vede solo uno non
        # potrebbe comunque accettarle. Il confine è il permesso, che è lo stesso della pagina in cui
        # si conferma.
        @consolidations = consolidations? ? consolidation_suggestions : []

        @report = ::Secrets::Attention::Report.new(
          anomaly_rows: @health ? @health.project_groups.flat_map(&:rows) : [],
          rotation_variables: @rotation&.variables || [],
          change_requests: @pending&.requests || [],
          consolidations: @consolidations
        )
        # CYRA-684 — la lista arrivava intera (misurata a 37 schermate): le righe si leggono a
        # pagine, i chip in alto restano i conteggi PIENI del report.
        @pagination = Pagination.from_array(listed_items, page: params[:page],
                                                           per: requested_per(Pagination::DEFAULT_PER))
      end

      private

      # F169 — C1: the bar narrows the rows; the counts on top stay the full report's.
      def listed_items
        items = @report.items
        project_ids = Array(params[:project_id]).reject(&:blank?)
        items = items.select { |item| project_ids.include?(item.project&.id) } if project_ids.any?
        kinds = Array(params[:kind]).reject(&:blank?)
        risks = Array(params[:risk]).reject(&:blank?)
        items = items.select { |item| kinds.include?(item.kind.to_s) } if kinds.any?
        items = items.select { |item| risks.include?(item.risk.to_s) } if risks.any?
        query = params[:q].to_s.strip.downcase
        return items if query.blank?

        items.select { |item| [ item.secret_name, item.project&.name ].compact.any? { |text| text.downcase.include?(query) } }
      end

      # CYRA-924 — the preview of secrets without a rule sorts on every column (C9): the most
      # urgent ones stay the shown ones, only their order changes.
      UNCOVERED_SORT_COLUMNS = {
        "variable" => ->(variable) { variable.name.to_s.downcase },
        "project" => ->(variable) { variable.project.name.to_s.downcase },
        "environment" => ->(variable) { variable.environment.label.to_s.downcase },
        "age" => ->(variable) { variable.rotated_at }
      }.freeze

      # Anomalie e rotazioni: stesso permesso org-level che gatava le due pagine di prima.
      def load_surveillance(projects)
        check = ::Secrets::HealthCheck.new(projects: projects)
        records = ::Secrets::Health::RecordAnomalies.call(
          organization: current_organization, anomalies: check.anomalies, project_ids: projects.map(&:id)
        ).value
        @health = ::Secrets::Health::Report.new(anomalies: check.anomalies, records: records)
        @rotation = ::Secrets::RotationReport.new(projects: projects)
        @uncovered = sorted_rows(@rotation.uncovered_preview.to_a, columns: UNCOVERED_SORT_COLUMNS, param: :uncovered_sort)
      end

      def consolidation_suggestions
        ::Secrets::Consolidation::Suggestion.where(organization_id: current_organization.id)
                                            .status_open.includes(:environment).ordered.to_a
      end

      def require_attention_view
        return if surveillance? || change_requests? || consolidations?

        redirect_to root_path, alert: t("member.forbidden")
      end

      def surveillance?
        return @surveillance if defined?(@surveillance)

        @surveillance = can?("secrets_audit.view")
      end

      def change_requests?
        vault_change_requests_nav_visible?
      end

      # Stesso permesso della pagina in cui la proposta si accetta: vedere una proposta che non si
      # potrebbe applicare sarebbe una riga da sistemare senza nessun modo di sistemarla.
      def consolidations?
        return @consolidations_visible if defined?(@consolidations_visible)

        @consolidations_visible = can?("shared_secrets.manage")
      end
    end
  end
end
