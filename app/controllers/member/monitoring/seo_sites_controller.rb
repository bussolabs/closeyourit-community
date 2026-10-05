# frozen_string_literal: true

module Member
  module Monitoring
    # I siti che il cockpit SEO tiene d'occhio (CYRA-528): dove attaccare la visita, quanto spesso,
    # fin dove spingersi. Lettura per chi vede i progetti; creare, modificare o eliminare un sito
    # richiede `seo.manage` — è configurazione, e decide a quale indirizzo il sistema andrà a
    # bussare per conto dell'organizzazione.
    class SeoSitesController < Member::BaseController
      permission_not_required "Siti osservati dei progetti visibili: sola lettura, il confine è la visibilità dei " \
                              "progetti.",
                              only: %i[index show pages performance issues]

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      SORT_COLUMNS = {
        "site" => :base_url,
        "checked" => :last_audited_at
      }.freeze

      # Quanti giri mostrare nello storico. Dieci: abbastanza per vedere se un guasto si ripete,
      # pochi per stare in una card senza paginazione.
      AUDITS_SHOWN = 10

      # Quanti rilievi e quante pagine anticipare nel riepilogo, prima di mandare alla scheda piena.
      # Il riepilogo risponde a «come sta questo sito», non «dammi tutto».
      PREVIEW = 5

      # Periodo del riquadro visite. Sette giorni come la dashboard delle statistiche: due periodi
      # diversi per lo stesso dato, a due clic di distanza, sono due numeri che sembrano in disaccordo.
      VISITS_RANGE = "7d"

      # CYRA-824 — il riquadro che si ricarica da solo quando il controllo del sito cambia stato.
      # Il nome è lo stesso che il segnale realtime bersaglia e sta in un posto solo (::Seo::Broadcast):
      # un rinominio da un lato spegnerebbe gli aggiornamenti senza rompere niente di visibile.
      #
      # Riepilogo e scheda velocità usano LO STESSO nome di proposito: il segnale non sa quale delle
      # due chi guarda ha davanti, e ognuna ricarica il proprio indirizzo. La richiesta del riquadro
      # si riconosce dall'intestazione che manda Turbo — MAI da un parametro nell'indirizzo — così il
      # collegamento che si condivide resta quello della pagina intera. Un endpoint solo, quindi
      # anche un gate solo: `set_site` (e il suo 404 anti-BOLA) vale per costruzione anche qui.
      LIVE_FRAME = ::Seo::Broadcast::LIVE_FRAME

      before_action :set_site, only: %i[show issues pages performance edit update destroy]
      before_action :require_manage, only: %i[edit update destroy]
      before_action :load_form_data, only: %i[new create edit update]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :project_id, only: :index

      def index
        scope = filter_by_project(visible.seo_sites.includes(:project, :environment))

        @sites = paginated(scope.ordered, columns: SORT_COLUMNS)
        load_filter_projects
        @open_counts = Seo::Issue.status_open.where(site_id: @sites.map(&:id)).group(:site_id).count
        # Uno per sito, scelto dal database (CYRA-818): `recent.index_by` scorreva dal nuovo al
        # vecchio e teneva l'ultimo scritto, cioè il giro PIÙ VECCHIO — la data era dell'ultimo
        # controllo e il numero di pagine di un altro. Caricava anche tutta la cronologia di ogni
        # sito per tenerne una riga.
        @last_audits = Seo::Audit.latest_per_site(@sites.map(&:id)).index_by(&:site_id)
        assign_counts
      end

      # La scheda di un sito: com'è messo adesso e cosa gli è successo. Il riepilogo ANTICIPA rilievi
      # e pagine invece di elencarli tutti — le due schede accanto esistono apposta — così la pagina
      # risponde a «come sta questo sito» senza diventare tre elenchi impilati.
      def show
        @audits = @site.audits.recent.limit(AUDITS_SHOWN).to_a
        # :page precaricata (CYRA-747): l'indirizzo mostrato accanto al rilievo è quello della sua
        # pagina, quindi senza preload l'anteprima farebbe una query per riga — come già fa la
        # scheda Rilievi qui sotto.
        @issues = site_issues.includes(:page).by_severity.limit(PREVIEW).to_a
        @pages = @site.pages.recent.limit(PREVIEW).to_a
        assign_site_counts
        assign_visits
        render_live_frame
      end

      def issues
        @issues = paginated(site_issues.includes(:page).by_severity, columns: SeoController::SORT_COLUMNS)
        assign_site_counts
      end

      def pages
        @pages = paginated(@site.pages.ordered, columns: SeoController::PAGE_SORT_COLUMNS)
        assign_site_counts
      end

      # Quanto è veloce il sito (CYRA-540). Due misure per strategia e non una media fra loro: il
      # laboratorio dice PERCHÉ è lento, il campo dice QUANTO lo è per le persone. Sono risposte a
      # due domande diverse, e un numero che le sommasse non risponderebbe a nessuna delle due.
      def performance
        # L'ultimo giro riuscito per ciascuna strategia in UNA query (`DISTINCT ON`), non una per
        # strategia: con due valori sarebbe innocuo, ma è la forma di un N+1 e Prosopite la ferma
        # giustamente prima che diventi un ciclo su qualcosa di più lungo.
        latest_runs = @site.lab_runs.status_completed
                      .select("DISTINCT ON (strategy) *")
                      .order(:strategy, started_at: :desc)
                      .index_by(&:strategy)
        @runs = Seo::LabRun.strategies.keys.index_with { |strategy| latest_runs[strategy] }
        # Il collegamento è quello dell'organizzazione DEL SITO (CYRA-546), non dell'installazione:
        # senza, la pagina prometterebbe misure che non arriveranno mai perché nessuno ha portato la
        # propria chiave.
        @lab_configured = ::Integrations::Resolve.connected?(organization: @site.project.organization_id,
                                                            provider: :pagespeed)
        assign_site_counts
        render_live_frame
      end

      def new
        @site = Seo::Site.new(frequency: :daily, max_pages: 100, follow_sitemap: true)
      end

      def create
        project = visible.projects.find_by(id: params[:project_id])
        return redirect_to(new_member_monitoring_seo_site_path, alert: t("member.monitoring.seo_sites.errors.project_required")) if project.nil?

        require_permission!("seo.manage", scope: project)
        # require_permission! REINDIRIZZA, non solleva: senza questa uscita l'azione proseguirebbe e
        # creerebbe il sito comunque, finendo poi su un DoubleRenderError invece che su un divieto.
        return if performed?

        @site = Seo::Site.new(site_params.merge(project:, environment_id: params[:environment_id],
                                                created_by: Current.account))

        if @site.save
          # Prima visita subito: un sito appena dichiarato che resta vuoto fino a notte sembra rotto.
          Seo::AuditSiteJob.perform_later(@site.id) if @site.enabled?
          redirect_to member_monitoring_seo_sites_path, notice: t("member.monitoring.seo_sites.notices.created")
        else
          @errors = @site.errors.to_hash
          render :new, status: :unprocessable_content
        end
      end

      def edit; end

      def update
        # Progetto e ambiente sono immutabili dopo la creazione: sono l'identità del sito (uno per
        # coppia). Cambiarli sarebbe un altro sito, con un'altra storia.
        if @site.update(site_params)
          redirect_to member_monitoring_seo_sites_path, notice: t("member.monitoring.seo_sites.notices.updated")
        else
          @errors = @site.errors.to_hash
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        @site.destroy
        redirect_to member_monitoring_seo_sites_path, notice: t("member.monitoring.seo_sites.notices.deleted")
      end

      private

      # CYRA-824 — quando arriva la richiesta del solo riquadro si rende la STESSA vista senza il
      # layout: il riquadro avvolge già tutto il contenuto della pagina, quindi non c'è una seconda
      # versione da tenere allineata a mano — e quella che si risparmia (barra laterale, notifiche,
      # menu) è proprio la parte che non c'entra niente con l'esito di un controllo.
      def render_live_frame
        render layout: false if turbo_frame_request_id == LIVE_FRAME
      end

      def set_site
        @site = visible.seo_sites.includes(:project, :environment).find(params[:id])
      end

      def site_issues = Seo::Issue.where(site_id: @site.id)

      # Le chip della scheda parlano di QUESTO sito, non dell'organizzazione: sono le stesse metriche
      # dell'elenco, ristrette. Mostrare qui i numeri globali direbbe il falso a chi le legge sotto il
      # nome di un sito.
      def assign_site_counts
        open_records = site_issues.status_open
        @open_count = open_records.count
        @critical_count = open_records.severity_critical.count
        @high_count = open_records.severity_high.count
        @ignored_count = site_issues.status_ignored.count
        @site_pages_count = @site.pages.count
      end

      # Le visite del progetto nell'ambiente del sito. `Types::Environment#code` è la stessa stringa
      # che l'ingest scrive su ogni pageview: è l'unico punto in cui il sito SEO e le statistiche si
      # toccano, e non serve nessuna chiave esterna nuova.
      #
      # Solo se il progetto raccoglie davvero: un riquadro di zeri su un progetto che non ha mai
      # acceso le statistiche sembra un guasto, non una configurazione mancante.
      def assign_visits
        return unless @site.project.analytics_enabled?

        @visits = ::Analytics::Query.new(project_id: @site.project_id, range: VISITS_RANGE,
                                         environment: @site.environment.code).headline
      end

      def require_manage = require_permission!("seo.manage", scope: @site.project)

      def load_form_data
        # Solo progetti con una piattaforma web e solo quelli davvero gestibili: non si offre un
        # bersaglio su cui il salvataggio verrebbe negato.
        @projects = visible.projects.analytics_capable.order(:name)
                                            .select { |project| can?("seo.manage", scope: project) }
      end

      def site_params
        params.permit(:base_url, :frequency, :max_pages, :follow_sitemap, :enabled)
      end

      # Le stesse chip delle altre schede, con gli stessi numeri: l'header è condiviso, e mostrare
      # zeri di comodo dove il conteggio non serviva a questa pagina significherebbe dire il falso
      # a chi lo legge.
      def assign_counts
        issues = visible.seo_issues
        @total_count = issues.status_open.count
        @critical_count = issues.status_open.severity_critical.count
        @high_count = issues.status_open.severity_high.count
        @ignored_count = issues.status_ignored.count
        @pages_count = visible.seo_pages.count
        @sites_count = visible.seo_sites.count
      end
    end
  end
end
