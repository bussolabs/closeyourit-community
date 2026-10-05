# frozen_string_literal: true

require "rails_helper"

# CYRA-584 — «Session replay» è il nome voluto (glossario), ed è l'unica voce del prodotto che non
# contiene nessuna delle parole con cui la funzione viene cercata: chi voleva «le registrazioni», «le
# visite» o «come si muovono le persone» poteva leggere il menu intero senza un aggancio — nel testo
# della sidebar «registrazion», «utent» e «visit» comparivano zero volte. La voce era ben visibile:
# non è un problema di visibilità, è un problema di parola.
#
# Due mosse, nessuna delle quali tocca il nome canonico. La voce si QUALIFICA con la parola con cui la
# si cerca («Session replay — registrazioni»), così l'aggancio sta dove si guarda. E la funzione
# diventa raggiungibile dalle statistiche del sito, che è la pagina dove chi cerca il comportamento
# delle persone arriva per prima: da lì un rimando porta alle registrazioni dello stesso progetto.
RSpec.describe "Member — trovare le registrazioni delle sessioni (CYRA-584)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  let(:project) { create(:project, organization: org, analytics_enabled: true).tap { |p| p.platforms << web } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def body = Nokogiri::HTML(response.body)

  describe "la voce del menu" do
    it "porta la parola con cui la funzione si cerca" do
      expect(I18n.t("member.nav.replays", locale: :it).downcase).to include("registrazioni")
      expect(I18n.t("member.nav.replays", locale: :en).downcase).to include("recordings")
    end

    it "non perde il nome canonico della funzione" do
      %i[it en].each do |lingua|
        expect(I18n.t("member.nav.replays", locale: lingua)).to start_with("Session replay")
      end
    end

    # La voce del menu ha 180 px e il testo si tronca in silenzio: col trattino lungo misurava 178,5
    # (Inter 12,5 px), un margine che il primo font di ripiego si mangia — e a sparire sarebbe proprio
    # la parola con cui la funzione si cerca. Il separatore stretto è quello di «Valhalla · God mode»,
    # e la soglia qui sotto tiene il testo abbastanza corto da non arrivarci mai vicino.
    it "sta nella larghezza del menu" do
      %i[it en].each do |lingua|
        voce = I18n.t("member.nav.replays", locale: lingua)
        expect(voce).to include("·")
        expect(voce.length).to be <= 30
      end
    end

    # Il glossario vuole UN nome solo: la scheda della panoramica dell'area apre la stessa pagina del
    # menu, quindi si legge uguale. Se restasse indietro, la stessa funzione avrebbe due nomi.
    it "la scheda della panoramica si chiama come la voce del menu" do
      %i[it en].each do |lingua|
        expect(I18n.t("member.overviews.observability.replays.label", locale: lingua))
          .to eq(I18n.t("member.nav.replays", locale: lingua))
      end
    end

    it "compare qualificata nel menu di ogni pagina" do
      sign_in(owner)

      get member_monitoring_replays_path

      voce = body.at_css('[data-test="member-nav-replays"]')
      expect(voce).to be_present
      expect(voce.text).to include(I18n.t("member.nav.replays"))
    end
  end

  describe "dalle statistiche del sito" do
    it "si arriva alle registrazioni delle sessioni" do
      create(:pageview, project:, path: "/pricing")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)

      rimando = body.at_css('[data-test="analytics-replays-link"]')
      expect(rimando).to be_present
      expect(rimando["href"]).to eq(member_monitoring_replays_path(project_id: project.id))
    end

    # Il rimando non inventa un terzo nome: si chiama come la voce del menu che apre la stessa pagina.
    it "il rimando si chiama come la voce del menu" do
      create(:pageview, project:, path: "/pricing")
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)

      expect(body.at_css('[data-test="analytics-replays-link"]').text.strip)
        .to include(I18n.t("member.nav.replays"))
    end

    # Il caso che serve davvero: il sito non ha ancora mandato una visita e la pagina insegna a
    # collegarlo. Anche lì chi cerca le registrazioni deve trovare la strada, altrimenti il rimando
    # esiste solo per chi ha già i dati.
    it "c'è anche prima della prima visita" do
      sign_in(owner)

      get member_monitoring_analytics_path(project_id: project.id)

      expect(body.at_css('[data-test="analytics-onboarding"]')).to be_present
      expect(body.at_css('[data-test="analytics-replays-link"]')).to be_present
    end
  end
end
