# frozen_string_literal: true

module Cli
  module V1
    # Vulnerabilità delle dipendenze sul canale CLI (CYRA-513). Cross-progetto come lo stream dei log,
    # non scoped a un progetto del path come gli error group: la sezione Member è cross-progetto, e su
    # una flotta di trenta repository la domanda vera è "dove sono le critiche", non "cosa ha questo".
    #
    # Scope = findings dei progetti VISIBILI (la lettura la governa l'accesso al progetto, nessuna
    # chiave d'azione). Il filtro project_id si risolve dentro visible_projects → fuori scope R404,
    # mai 403: una riga di un progetto che non vedi non esiste, non è "vietata".
    #
    # Il triage — ignora, riapri, promuovi — vive nei sub-controller singleton (vulnerabilities/), come
    # per gli error group; qui restano lettura e la scansione su richiesta.
    class VulnerabilitiesController < Cli::V1::BaseController
      # Rescan muta lo stato del progetto (riscrive i findings) → stesso gate del triage. Il progetto
      # si risolve prima, così uno fuori scope dà 404 senza mai arrivare al controllo del permesso.
      before_action :set_rescan_project!, only: :rescan
      before_action -> { require_permission!("vulnerabilities.triage", scope: @rescan_project) }, only: :rescan

      def index
        scope = scoped_findings.includes(:advisory, :project, package: :manifest)
        records, meta = paginate(filtered(scope).by_severity)
        render_ok(VulnerabilityFindingSerializer.new(records), meta: meta)
      end

      def show
        finding = visible_findings.includes(:advisory, :project, package: :manifest).find(params[:id])
        render_ok(VulnerabilityFindingSerializer.new(finding))
      end

      # Seconda lista della stessa sezione: le versioni di linguaggio fuori supporto sono la causa a
      # monte delle falle che nessun aggiornamento di libreria può chiudere.
      def runtimes
        scope = scoped_runtimes.includes(:project).ordered
        records, meta = paginate(scope)
        render_ok(VulnerabilityRuntimeStatusSerializer.new(records), meta: meta)
      end

      # Scansione su richiesta: chi ha appena aggiornato una libreria non deve aspettare il giro
      # notturno per vedere sparire la riga. Un progetto per volta, come nel Member.
      def rescan
        ::Vulnerabilities::ScanProjectJob.perform_later(@rescan_project.id)
        render_ok({ project_id: @rescan_project.id, scan: "queued" })
      end

      private

      def visible_findings
        ::Vulnerabilities::Finding.where(project_id: visible_projects.select(:id))
      end

      def scoped_findings
        return visible_findings if params[:project_id].blank?

        ::Vulnerabilities::Finding.where(project: visible_projects.find(params[:project_id]))
      end

      def scoped_runtimes
        return ::Vulnerabilities::RuntimeStatus.where(project_id: visible_projects.select(:id)) if params[:project_id].blank?

        ::Vulnerabilities::RuntimeStatus.where(project: visible_projects.find(params[:project_id]))
      end

      # Un valore fuori vocabolario è un filtro che non esiste, non una richiesta malformata: si
      # scarta e si restituisce tutto (stesso comportamento del canale Member).
      def filtered(scope)
        scope = scope.where(status: params[:status]) if ::Vulnerabilities::Finding.statuses.key?(params[:status])
        if ::Vulnerabilities::Advisory.severities.key?(params[:severity])
          scope = scope.joins(:advisory).where(vulnerabilities_advisories: { severity: params[:severity] })
        end
        return scope if params[:package].blank?

        scope.joins(:package).where("vulnerabilities_packages.name ILIKE :q", q: "%#{params[:package]}%")
      end

      def set_rescan_project! = @rescan_project = visible_projects.find(params[:project_id])
    end
  end
end
