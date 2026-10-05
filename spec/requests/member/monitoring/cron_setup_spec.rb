# frozen_string_literal: true

require "rails_helper"

# CYRA-485 — la pagina dei lavori programmati non aveva nessun comando per aggiungerne uno e nessuna
# pagina spiegava come si fa da fuori: niente indirizzo, niente comando, nessuna guida. Chi voleva
# tenere d'occhio il proprio salvataggio notturno non aveva nessun punto di partenza.
RSpec.describe "Member — mettere un lavoro programmato sotto controllo", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:, name: "Negozio") }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  it "il comando per aggiungerne uno è visibile a lista vuota" do
    sign_in(owner)

    get member_monitoring_cron_monitors_path

    expect(body.at_css("[data-test='crons-empty-setup']")).to be_present
  end

  # Il punto della Definition of Done: anche con la lista piena, altrimenti chi ne ha uno solo non
  # scopre mai come aggiungere il secondo.
  it "resta visibile anche quando la lista non è vuota" do
    sign_in(owner)
    create(:cron_monitor, project:)

    get member_monitoring_cron_monitors_path

    expect(body.at_css("[data-test='crons-setup-cta']")).to be_present
  end

  describe "le istruzioni" do
    it "mostrano l'indirizzo da chiamare e un comando pronto" do
      sign_in(owner)
      project

      get setup_member_monitoring_cron_monitors_path

      testo = body.at_css("[data-test='cron-setup']").text
      expect(testo).to include("/api/v1/projects/#{project.id}/crons/")
      expect(testo).to include("curl -X POST")
    end

    # Nell'indirizzo non c'è nessun segreto, ma il token non si stampa mai: resta un segnaposto.
    it "non stampano mai il valore di una credenziale" do
      sign_in(owner)
      project

      get setup_member_monitoring_cron_monitors_path

      expect(response.body).to include("Bearer &lt;token di ingest del progetto&gt;")
        .or include("Bearer <token di ingest del progetto>")
      expect(response.body).not_to match(/cyi_t_\w/)
    end

    it "mostrano anche come dire che il lavoro è fallito" do
      sign_in(owner)
      project

      get setup_member_monitoring_cron_monitors_path

      expect(body.at_css("[data-test='cron-setup']").text).to include("status=fail")
    end

    it "senza progetti visibili lo dichiarano, invece di mostrare un indirizzo finto" do
      sign_in(owner)

      get setup_member_monitoring_cron_monitors_path

      expect(body.at_css("[data-test='cron-setup-no-project']")).to be_present
    end
  end

  it "la pagina di un lavoro mostra il proprio indirizzo di controllo" do
    sign_in(owner)
    monitor = create(:cron_monitor, project:, slug: "backup-notturno")

    get member_monitoring_cron_monitor_path(monitor)

    pannello = body.at_css("[data-test='cron-check-in-url']")
    expect(pannello).to be_present
    expect(pannello.text).to include("/crons/backup-notturno/check_in")
  end

  describe "la guida" do
    it "esiste ed è raggiungibile dall'elenco delle guide" do
      sign_in(owner)

      get member_guides_path
      expect(body.at_css("[data-test='member-guides-card-crons']")).to be_present

      get member_guides_crons_path
      expect(response).to have_http_status(:ok)
      expect(body.at_css("[data-test='member-guide-crons']")).to be_present
    end

    it "spiega la differenza fra mancato e fallito prima di configurare" do
      sign_in(owner)

      get member_guides_crons_path

      expect(response.body).to include(I18n.t("member.crons.legend_missed"))
      expect(response.body).to include(I18n.t("member.crons.legend_fail"))
    end
  end
end
