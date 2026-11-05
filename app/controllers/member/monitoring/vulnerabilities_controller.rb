# frozen_string_literal: true

module Member
  module Monitoring
    # Vulnerabilità delle dipendenze (CYRA-506). Lettura per chiunque veda i progetti (scoping
    # visible.vulnerabilities, anti-BOLA); il triage — ignora, riapri, promuovi — richiede
    # `vulnerabilities.triage` sul progetto della riga.
    #
    # `runtimes` è la seconda tab della stessa sezione: le versioni di linguaggio fuori supporto sono
    # la causa a monte delle falle che nessun aggiornamento di libreria può chiudere.
    class VulnerabilitiesController < Member::BaseController
      permission_not_required "Falle delle dipendenze dei progetti visibili: sola lettura, il triage è gated più " \
                              "sotto.",
                              only: %i[index show runtimes]

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      # Quanti file non letti si nominano nell'avviso: oltre, il conteggio dice il resto. Un monorepo
      # con quaranta lockfile rotti riempirebbe la testata invece di avvisare.
      UNVERIFIED_PREVIEW = 5

      SORT_COLUMNS = {
        "severity" => { expr: "vulnerabilities_advisories.severity", joins: :advisory },
        "package" => { expr: "LOWER(vulnerabilities_packages.name)", joins: :package },
        "project" => { expr: "LOWER(projects.name)", joins: :project },
        "seen" => :last_seen_at
      }.freeze

      before_action :set_finding, only: %i[show ignore reopen promote]
      before_action :require_triage, only: %i[ignore reopen promote]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :severity, :status, :project_id, :q, :sort, only: :index

      def index
        scope = base_scope.includes(:advisory, :project, package: :manifest)
        scope = scope.where(status: status_filter) if status_filter.any?
        scope = scope.joins(:advisory).where(vulnerabilities_advisories: { severity: severity_filter }) if severity_filter.any?
        scope = filter_by_project(scope)
        scope = filter_by_search(scope, "vulnerabilities_packages.name", joins: :package)

        @findings = paginated(scope.by_severity, columns: SORT_COLUMNS)
        load_filter_projects
        @saved_views = saved_views_for("vulnerabilities")
        assign_counts
        assign_unverified_manifests
      end

      def show
        @manifest = @finding.package.manifest
      end

      # CYRA-924 — every runtime column sorts (C9).
      RUNTIME_SORT_COLUMNS = {
        "runtime" => "LOWER(vulnerabilities_runtime_statuses.name)",
        "version" => :version,
        "latest" => :latest,
        "eol_on" => :eol_on,
        "project" => "(SELECT LOWER(projects.key) FROM projects WHERE projects.id = vulnerabilities_runtime_statuses.project_id)",
        "manifest" => :source_path
      }.freeze

      def runtimes
        @runtime_statuses = sorted(filter_by_project(visible.runtime_statuses.includes(:project).ordered), columns: RUNTIME_SORT_COLUMNS)
        load_filter_projects
        assign_counts
      end

      # Ignora = convivo col rischio. Non torna aperta da sola alla scansione successiva: sarebbe un
      # modo per rimettere in lista una decisione già presa.
      def ignore
        @finding.update!(status: :ignored, triage_note: params[:triage_note].presence)
        redirect_back_to_list(notice_key: "ignored")
      end

      def reopen
        @finding.update!(status: :open, resolved_at: nil)
        redirect_back_to_list(notice_key: "reopened")
      end

      def promote
        result = Vulnerabilities::PromoteToTicket.call(group: @finding, reporter: Current.account)

        if result.ok?
          redirect_to member_ticket_path(result.value),
                      notice: t("member.monitoring.vulnerabilities.notices.promoted")
        else
          redirect_to member_monitoring_vulnerability_path(@finding),
                      alert: t("member.monitoring.vulnerabilities.errors.promote_failed")
        end
      end

      # Scansione su richiesta: chi ha appena aggiornato una libreria non deve aspettare la notte per
      # vedere sparire la riga. Un progetto per volta — è quello che l'utente sta guardando.
      def rescan
        project = visible.projects.find_by(id: params[:project_id])
        if project.nil?
          nothing_to_authorize!
          return redirect_to(member_monitoring_vulnerabilities_path)
        end

        require_permission!("vulnerabilities.triage", scope: project)
        Vulnerabilities::ScanProjectJob.perform_later(project.id)

        redirect_to member_monitoring_vulnerabilities_path(project_id: [ project.id ]),
                    notice: t("member.monitoring.vulnerabilities.notices.rescan_started")
      end

      private

      def base_scope = visible.vulnerabilities

      def set_finding
        @finding = base_scope.includes(:advisory, package: :manifest).find_by(id: params[:id])
        # Anti-BOLA: una riga di un progetto che non vedi non esiste, non è "vietata".
        raise ActiveRecord::RecordNotFound if @finding.nil?
      end

      def require_triage = require_permission!("vulnerabilities.triage", scope: @finding.project)

      def status_filter = enum_filter(:status, Vulnerabilities::Finding.statuses.keys)

      def severity_filter = enum_filter(:severity, Vulnerabilities::Advisory.severities.keys)

      # Le chip dell'header contano SEMPRE su tutto ciò che è visibile, non sulla pagina corrente né
      # sul filtro attivo: servono a dire quanto c'è, non quanto se ne vede adesso.
      #
      # CYRA-565 — le prime tre restano ristrette alle APERTE (una falla risolta o messa da parte non
      # è un problema da guardare oggi), e per questo si chiamano così: quando si chiamavano «Totale»
      # e «Alte» contraddicevano l'elenco sotto, che invece mostra ogni stato.
      def assign_counts
        findings = visible.vulnerabilities
        @open_count = findings.status_open.count
        @critical_count = findings.status_open.joins(:advisory)
                                 .where(vulnerabilities_advisories: { severity: :critical }).count
        @high_count = findings.status_open.joins(:advisory)
                             .where(vulnerabilities_advisories: { severity: :high }).count
        @ignored_count = findings.status_ignored.count
        @runtimes_eol_count = visible.runtime_statuses.state_eol.count
        # F084 — how fresh the counts are: the latest scan of any lockfile the viewer sees.
        @last_scan_at = visible.vulnerability_manifests.maximum(:scanned_at)
      end

      # CYRA-810 — i lockfile che l'ultima scansione non è riuscita a leggere. Vanno detti anche (anzi:
      # soprattutto) quando l'elenco è vuoto: lì «nessuna vulnerabilità nota» sarebbe la lettura più
      # sbagliata possibile di un controllo che su quei file non ha guardato. Solo sulla tab Librerie:
      # i lockfile non c'entrano con le versioni di linguaggio.
      def assign_unverified_manifests
        unverified = visible.vulnerability_manifests.failing
        @unverified_manifests_count = unverified.count
        @unverified_manifests = unverified.includes(:project).ordered.limit(UNVERIFIED_PREVIEW).to_a
      end

      def redirect_back_to_list(notice_key:)
        redirect_to member_monitoring_vulnerability_path(@finding),
                    notice: t("member.monitoring.vulnerabilities.notices.#{notice_key}")
      end
    end
  end
end
