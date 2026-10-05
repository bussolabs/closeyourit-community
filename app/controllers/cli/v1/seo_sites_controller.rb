# frozen_string_literal: true

module Cli
  module V1
    # I siti sotto controllo SEO sul canale CLI (CYRA-528): elenco, dichiarazione, modifica,
    # rimozione. Dichiarare un sito è configurazione — decide a quale indirizzo il sistema andrà a
    # bussare per conto dell'organizzazione — quindi il gate è `seo.manage`, non il triage.
    #
    # La lettura resta governata dalla visibilità del progetto, come ovunque nel canale.
    class SeoSitesController < Cli::V1::BaseController
      before_action :set_site!, only: %i[show update destroy]
      before_action -> { require_permission!("seo.manage", scope: @site.project) }, only: %i[update destroy]

      def index
        scope = visible_sites.includes(:project, :environment)
        scope = scope.where(project: visible_projects.find(params[:project_id])) if params[:project_id].present?
        records, meta = paginate(scope.ordered)
        render_ok(SeoSiteSerializer.new(records), meta: meta)
      end

      # La scheda di un sito (CYRA-541): le stesse cose che si vedono aprendolo dalle schermate —
      # com'è configurato, quanti rilievi ha aperti, com'è andato l'ultimo giro, quanto è veloce.
      # Lettura: la governa la visibilità del progetto, come tutto il resto del canale.
      def show
        render_ok(SeoSiteSerializer.new(@site, params: card_params))
      end

      def create
        project = visible_projects.find(params[:project_id])
        # Il gate del canale CLI risponde e ritorna false: senza questa uscita il sito nascerebbe
        # comunque, e la risposta di divieto arriverebbe con la riga già scritta.
        return unless require_permission!("seo.manage", scope: project)

        site = ::Seo::Site.new(site_params.merge(project:, environment_id: params[:environment_id],
                                                 created_by: Current.account))
        return render_invalid(site) unless site.save

        # Prima visita subito: un sito appena dichiarato che resta vuoto sembra rotto.
        ::Seo::AuditSiteJob.perform_later(site.id)
        render_created(SeoSiteSerializer.new(site))
      end

      def update
        # Progetto e ambiente non si cambiano: sono l'identità del sito (uno per coppia).
        return render_invalid(@site) unless @site.update(site_params)

        render_ok(SeoSiteSerializer.new(@site))
      end

      def destroy
        @site.destroy
        render_ok({ id: @site.id, deleted: true })
      end

      private

      # I dati in più della scheda. Il controllore li raccoglie, la forma la decide il serializer:
      # `lab_runs` c'è SEMPRE (anche vuoto) perché è il marcatore che distingue la scheda dall'elenco,
      # dove questi blocchi non si pagherebbero.
      def card_params
        { issue_counts: issue_counts, pages_count: @site.pages.count,
          last_audit: @site.audits.recent.first, lab_runs: last_lab_runs,
          lab_configured: lab_configured? }
      end

      # Due query per quattro numeri, non quattro count a fila: due count identici nella forma sono un
      # N+1 travestito, e Prosopite li ferma giustamente. Sono gli stessi conteggi delle chip della
      # scheda Member, ristretti a QUESTO sito.
      def issue_counts
        issues = ::Seo::Issue.where(site_id: @site.id)
        by_status = issues.group(:status).count
        by_severity = issues.status_open.group(:severity).count
        { open: by_status.fetch("open", 0), critical: by_severity.fetch("critical", 0),
          high: by_severity.fetch("high", 0), ignored: by_status.fetch("ignored", 0) }
      end

      # L'ultimo giro RIUSCITO per ciascuna strategia in UNA query (`DISTINCT ON`), come la scheda
      # Member: un giro fallito non sostituisce mai i numeri buoni di prima. Le strategie senza
      # nemmeno un giro riuscito escono dall'elenco, non entrano con i campi a nulla.
      def last_lab_runs
        latest_runs = @site.lab_runs.status_completed
                      .select("DISTINCT ON (strategy) *")
                      .order(:strategy, started_at: :desc)
                      .index_by(&:strategy)
        ::Seo::LabRun.strategies.keys.index_with { |strategy| latest_runs[strategy] }.compact
      end

      # Se l'organizzazione DEL SITO ha collegato il servizio di misura (CYRA-546). Senza, le misure
      # non arriveranno mai: un blocco assente si leggerebbe come «è ancora presto» invece di
      # «manca il collegamento».
      def lab_configured?
        ::Integrations::Resolve.connected?(organization: @site.project.organization_id, provider: :pagespeed)
      end

      def visible_sites = ::Seo::Site.where(project_id: visible_projects.select(:id))

      # Anti-BOLA: lookup dentro i progetti visibili PRIMA del gate (invisibile → 404, non 403).
      def set_site!
        @site = visible_sites.includes(:project, :environment).find(params[:id])
      end

      def site_params
        params.permit(:base_url, :frequency, :max_pages, :follow_sitemap, :enabled)
      end

      # Gli errori del modello nella forma degli altri 422 del canale: messaggio leggibile più i
      # dettagli per campo, così la CLI può dire QUALE campo rifiutare senza indovinare.
      def render_invalid(site)
        render_error("R422-SEO-002", site.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: site.errors.to_hash)
      end
    end
  end
end
