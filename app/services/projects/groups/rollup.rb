# frozen_string_literal: true

module Projects
  module Groups
    # Riassunto dei progetti di un gruppo (CYRA-362): errori aperti, ticket non chiusi, disponibilità
    # e ultimo rilascio dell'insieme. La pagina del gruppo elencava solo i nomi dei progetti, e per
    # sapere come stesse il prodotto bisognava aprirli uno per uno.
    #
    # I numeri arrivano da aree diverse, quindi il periodo è FISSATO qui e dichiarato in pagina
    # (`member.groups.rollup.scope_hint`): errori e ticket sono lo stato attuale, la disponibilità è
    # la media delle ultime 24 ore (stessa finestra della fascia salute del progetto), il rilascio è
    # il più recente fra i progetti. Un riassunto senza periodo dichiarato sarebbe solo un altro
    # numero ambiguo.
    #
    # Costo fisso: una query per dominio sull'INSIEME dei progetti (mai una per progetto), così le
    # righe della lista possono mostrare i propri numeri senza N+1.
    class Rollup
      UPTIME_WINDOW = 24.hours

      def initialize(projects)
        @projects = Array(projects)
      end

      def project_ids = @project_ids ||= @projects.map(&:id)

      def any_projects? = @projects.any?

      # { project_id => errori non risolti }. Un progetto senza errori non compare: `.to_i` a valle.
      def errors_by_project
        @errors_by_project ||= return_empty_or do
          Errors::Group.where(project_id: project_ids).status_unresolved.group(:project_id).count
        end
      end

      # { project_id => Ticketing::Tally }, la stessa definizione di "non chiusi" della pagina
      # progetto (categoria da fare + in corso, quindi anche in revisione).
      def tickets_by_project
        @tickets_by_project ||= return_empty_or do
          Ticketing::Tally.by_project(Ticketing::Ticket.where(project_id: project_ids))
        end
      end

      def errors_unresolved = errors_by_project.values.sum

      def tickets_unresolved = tickets_by_project.values.sum(&:unresolved)

      def tickets_total = tickets_by_project.values.sum(&:total)

      def tally_for(project) = tickets_by_project[project.id] || Ticketing::Tally.empty

      def errors_for(project) = errors_by_project[project.id].to_i

      # Media delle percentuali delle ultime 24 ore dei monitor del gruppo. `nil` quando non c'è
      # nemmeno un controllo in finestra: un insieme senza dati non vale 0% (che è un guasto totale).
      def uptime_percent
        return @uptime_percent if defined?(@uptime_percent)

        @uptime_percent = begin
          percents = uptime_percents.values.compact
          percents.any? ? (percents.sum / percents.size).round(2) : nil
        end
      end

      # Il rilascio più recente fra i progetti del gruppo (o nil), col suo progetto già caricato.
      def last_release
        return @last_release if defined?(@last_release)

        @last_release = return_nil_or do
          ::Projects::Release.where(project_id: project_ids).includes(:project).recent.first
        end
      end

      private

      def uptime_percents
        return {} unless any_projects?

        monitor_ids = Uptime::Monitor.where(project_id: project_ids).pluck(:id)
        Uptime::Monitor.uptime_percents(monitor_ids, UPTIME_WINDOW.ago)
      end

      # Gruppo senza progetti: niente query (un `where(project_id: [])` resta pur sempre un giro al DB).
      def return_empty_or = any_projects? ? yield : {}

      def return_nil_or = any_projects? ? yield : nil
    end
  end
end
