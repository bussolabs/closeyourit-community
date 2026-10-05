# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring vulnerabilities", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def finding_in(target_project, severity: :high, **attrs)
    manifest = create(:vulnerability_manifest, project: target_project)
    package = create(:vulnerability_package, manifest: manifest, name: "rails", version: "7.0.0")
    create(:vulnerability_finding, project: target_project, package: package,
                                   advisory: create(:vulnerability_advisory, severity: severity), **attrs)
  end

  describe "GET index" do
    it "elenca le vulnerabilità dei progetti visibili" do
      finding = finding_in(project)
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("rails@7.0.0")
      expect(response.body).to include("vulnerabilities-counts")
      expect(response.body).to include(finding.display_id)
    end

    it "la riga dice da quanto è stata vista («fa») e il nome del progetto dietro la sigla" do
      finding_in(project, last_seen_at: 2.hours.ago)
      owner.update!(locale: "it")
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      riga = Nokogiri::HTML(response.body).at_css("[data-test='vulnerability-row']")
      expect(riga.text).to include("circa 2 ore fa")
      expect(riga.at_css("[title='#{project.name}']").text).to eq(project.key)
    end

    # F084 — G5: the counts say how fresh they are.
    it "says when the last scan ran, next to the counts" do
      finding = finding_in(project)
      finding.package.manifest.update!(scanned_at: 3.hours.ago)
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      stat = Capybara.string(response.body).find("[data-test='vulnerabilities-stat-last-scan']")
      expect(stat.text).to include("about 3 hours ago")
    end

    it "says the libraries were never scanned when no scan has run" do
      finding_in(project).package.manifest.update!(scanned_at: nil)
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      stat = Capybara.string(response.body).find("[data-test='vulnerabilities-stat-last-scan']")
      expect(stat.text).to include(I18n.t("member.monitoring.vulnerabilities.stats.never_scanned"))
    end

    # F085 — "No fixed version" was a dead end: the row and the page now say what is left to do.
    it "says what to do when no release fixes the finding yet" do
      finding = finding_in(project, fixed_version: nil)
      sign_in(owner)

      get member_monitoring_vulnerabilities_path
      row = Capybara.string(response.body).find("##{ActionView::RecordIdentifier.dom_id(finding)}")
      expect(row.find("[data-test='vulnerability-no-fix']")[:title]).to eq(I18n.t("member.monitoring.vulnerabilities.no_fix_hint"))

      get member_monitoring_vulnerability_path(finding)
      expect(response.body).to include('data-test="vulnerability-no-fix-note"')
    end

    it "un conteggio a zero non è rosso: il colore d'allarme resta per quando c'è qualcosa" do
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      chip = Nokogiri::HTML(response.body).at_css("[data-test='vulnerabilities-stat-critical']")
      expect(chip.to_html).not_to include("text-red-600")
    end

    it "NON mostra le vulnerabilità di un'altra organizzazione" do
      finding_in(create(:project))
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect(response.body).not_to include("rails@7.0.0")
    end

    it "filtra per gravità" do
      finding_in(project, severity: :critical)
      other_manifest = create(:vulnerability_manifest, project: project, path: "web/package-lock.json",
                                                       ecosystem: "npm")
      low_package = create(:vulnerability_package, manifest: other_manifest, name: "lodash",
                                                   version: "4.17.15", ecosystem: "npm")
      create(:vulnerability_finding, project: project, package: low_package,
                                     advisory: create(:vulnerability_advisory, severity: :low))
      sign_in(owner)

      get member_monitoring_vulnerabilities_path(severity: [ "critical" ])

      expect(response.body).to include("rails@7.0.0")
      expect(response.body).not_to include("lodash@4.17.15")
    end

    it "senza vulnerabilità mostra lo stato vuoto, non una tabella vuota" do
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect(response.body).to include("vulnerabilities-empty")
    end

    # CYRA-565 — la testata diceva «Totale: 0» sopra una tabella piena, e «Alte: 0» conviveva con
    # righe marcate «Alta»: quei chip contano solo le aperte, ma si presentavano come il conto di
    # tutto. Chi apriva la pagina non sapeva se i problemi fossero zero o otto.
    describe "conteggi in testata con righe messe da parte" do
      def chip(body, name)
        Nokogiri::HTML(body).at_css("[data-test='vulnerabilities-stat-#{name}']")&.text&.squish
      end

      def ignored_high_findings(count)
        manifest = create(:vulnerability_manifest, project: project)
        Array.new(count) do
          package = create(:vulnerability_package, manifest: manifest)
          create(:vulnerability_finding, project: project, package: package, status: :ignored,
                                         advisory: create(:vulnerability_advisory, severity: :high))
        end
      end

      it "il chip dei conti dichiara di contare le aperte, non il totale" do
        ignored_high_findings(2)
        sign_in(owner)

        get member_monitoring_vulnerabilities_path

        expect(chip(response.body, "total")).to be_nil
        expect(chip(response.body, "open"))
          .to eq("0 #{I18n.t('member.monitoring.vulnerabilities.stats.open').downcase}")
      end

      it "i chip di gravità dicono che riguardano le aperte, mentre la tabella mostra le righe" do
        ignored_high_findings(2)
        sign_in(owner)

        get member_monitoring_vulnerabilities_path

        expect(chip(response.body, "high"))
          .to eq("0 #{I18n.t('member.monitoring.vulnerabilities.stats.high').downcase}")
        expect(chip(response.body, "ignored"))
          .to eq("2 #{I18n.t('member.monitoring.vulnerabilities.stats.ignored').downcase}")
        expect(Nokogiri::HTML(response.body).css("[data-test='vulnerability-row']").size).to eq(2)
      end
    end
  end

  # CYRA-810 — un lockfile che la scansione non è riuscita a leggere non prova niente. Finché resta
  # così la pagina deve dirlo: senza, «Nessuna vulnerabilità nota» è la frase che l'utente legge
  # proprio mentre il controllo è cieco su un pezzo del progetto.
  describe "GET index con file delle dipendenze non letti" do
    # L'ecosistema si deduce dal nome del file, come fa la scoperta dei lockfile: un manifest npm
    # chiamato Gemfile.lock è uno stato che la scansione non produce mai.
    def unread_manifest(target_project, path: "web/package-lock.json")
      create(:vulnerability_manifest, :failing, project: target_project, path: path,
                                                ecosystem: Vulnerabilities::Ecosystem.for_path(path))
    end

    it "dichiara il controllo incompleto e nomina i file non letti" do
      unread_manifest(project)
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect(response.body).to include("vulnerabilities-unverified")
      expect(response.body).to include("web/package-lock.json")
    end

    it "lo dichiara anche quando non c'è nessuna vulnerabilità da mostrare" do
      unread_manifest(project)
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect(response.body).to include("vulnerabilities-empty")
      expect(response.body).to include("vulnerabilities-unverified")
    end

    # Due file non letti: il conteggio va al plurale e i nomi arrivano entrambi. Vale anche come
    # prova che il progetto di ogni riga è precaricato (guardia letture a raffica, CYRA-747).
    it "li nomina tutti quando sono più d'uno" do
      unread_manifest(project)
      unread_manifest(project, path: "api/Gemfile.lock")
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect(response.body).to include("web/package-lock.json")
      expect(response.body).to include("api/Gemfile.lock")
      expect(response.body).to include(
        I18n.t("member.monitoring.vulnerabilities.unverified.title", count: 2)
      )
    end

    it "con tutti i file letti non dichiara niente" do
      create(:vulnerability_manifest, project: project)
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect(response.body).not_to include("vulnerabilities-unverified")
    end

    it "NON nomina i file di un'organizzazione che non vedi" do
      unread_manifest(create(:project), path: "altrove/package-lock.json")
      sign_in(owner)

      get member_monitoring_vulnerabilities_path

      expect(response.body).not_to include("vulnerabilities-unverified")
      expect(response.body).not_to include("altrove/package-lock.json")
    end
  end

  describe "GET show" do
    it "mostra il dettaglio con il riferimento pubblico" do
      finding = finding_in(project)
      sign_in(owner)

      get member_monitoring_vulnerability_path(finding)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(finding.advisory.osv_id)
    end

    # CYRA-552 — i comandi di triage vivono solo qui: se la scheda non si apre, la vulnerabilità
    # non si può lavorare. Gravità non promuovibile e nessuna versione che corregge sono il caso
    # normale, non un'eccezione.
    it "si apre anche senza versione che corregge e con gravità non promuovibile" do
      finding = finding_in(project, severity: :moderate, fixed_version: nil)
      sign_in(owner)

      get member_monitoring_vulnerability_path(finding)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("vulnerability-stat-fixed")
      expect(response.body).to include("vulnerability-stat-severity")
    end

    it "una riga di un'altra organizzazione non esiste (404, non 403)" do
      foreign = finding_in(create(:project))
      sign_in(owner)

      get member_monitoring_vulnerability_path(foreign)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET runtimes" do
    it "elenca i runtime con il loro stato di supporto" do
      create(:vulnerability_runtime_status, :eol, project: project, name: "ruby")
      sign_in(owner)

      get runtimes_member_monitoring_vulnerabilities_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ruby")
      expect(response.body).to include("runtimes-table")
    end
  end

  describe "triage" do
    it "l'owner può ignorare e riaprire" do
      finding = finding_in(project)
      sign_in(owner)

      patch ignore_member_monitoring_vulnerability_path(finding)
      expect(finding.reload).to be_status_ignored

      patch reopen_member_monitoring_vulnerability_path(finding)
      expect(finding.reload).to be_status_open
    end

    it "chi non ha il permesso vede la pagina ma non può ignorare" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_member, project: project, account: member) if defined?(ProjectMember)
      finding = finding_in(project)
      sign_in(member)

      patch ignore_member_monitoring_vulnerability_path(finding)

      expect(response).not_to have_http_status(:ok)
      expect(finding.reload).to be_status_open
    end

    it "la promozione crea un ticket collegato" do
      create(:ticket_status, organization: org, code: "open", position: 0)
      create(:ticket_priority, organization: org, code: "high", position: 0)
      finding = finding_in(project)
      sign_in(owner)

      expect { post promote_member_monitoring_vulnerability_path(finding) }
        .to change(Ticketing::Ticket, :count).by(1)
      expect(finding.reload).to be_promoted
    end
  end

  describe "POST rescan" do
    it "accoda la scansione del progetto scelto" do
      sign_in(owner)

      expect { post rescan_member_monitoring_vulnerabilities_path(project_id: project.id) }
        .to have_enqueued_job(Vulnerabilities::ScanProjectJob).with(project.id)
    end

    it "un progetto non visibile non fa partire nulla" do
      foreign = create(:project)
      sign_in(owner)

      expect { post rescan_member_monitoring_vulnerabilities_path(project_id: foreign.id) }
        .not_to have_enqueued_job(Vulnerabilities::ScanProjectJob)
    end
  end

  it "la voce compare nel gruppo Osservabilità" do
    sign_in(owner)

    get member_monitoring_vulnerabilities_path

    expect(response.body).to include("member-nav-vulnerabilities")
    expect(response.body).to include("member-nav-group-observability")
  end
end
