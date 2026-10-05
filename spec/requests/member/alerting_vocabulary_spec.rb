# frozen_string_literal: true

require "rails_helper"

# CYRA-480 — lo stesso evento aveva un nome nelle regole e un altro nelle impostazioni personali, e le
# due pagine non si citavano: non essendo scritto da nessuna parte quale leva prevalga, un'idea
# sbagliata produceva silenzi non voluti.
RSpec.describe "Member::Alerting — un nome solo e una gerarchia dichiarata (CYRA-480)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "il nome dell'evento nelle regole è quello del catalogo, non un secondo vocabolario" do
    rule = create(:alerting_rule, organization: org, event_type: :cron_missed)

    get member_alerting_rule_path(rule)

    expect(response.body).to include(Notifications::Catalog.entry("cron_missed").title)
  end

  it "regole e impostazioni personali chiamano l'evento allo stesso modo" do
    create(:alerting_rule, organization: org, event_type: :uptime_up)

    get member_alerting_rules_path
    rules_page = response.body

    get member_notification_preferences_path
    preferences_page = response.body

    nome = Notifications::Catalog.entry("uptime_up").title
    expect(rules_page).to include(nome)
    expect(preferences_page).to include(nome)
  end

  it "ogni evento delle regole ha una voce nel catalogo: nessun nome può divergere" do
    fuori_catalogo = Alerting::Rule.event_types.keys - Notifications::Catalog.event_types
    expect(fuori_catalogo).to be_empty
  end

  # CYRA-838 — il filtro Evento dell'index aveva una SECONDA lista di nomi (member.alerting.event_types),
  # incompleta: «Vulnerability New», «Runtime Eol», «Seo Issue New» tra le voci italiane. Il filtro
  # deve leggere lo stesso catalogo del modulo della regola, in tutte e due le lingue.
  describe "il filtro Evento dell'index" do
    { it: { vulnerability_new: "Nuova vulnerabilità", runtime_eol: "Versione senza più aggiornamenti",
            seo_issue_new: "Nuovo rilievo SEO" },
      en: { vulnerability_new: "New vulnerability", runtime_eol: "Version no longer updated",
            seo_issue_new: "New SEO finding" } }.each do |lingua, attesi|
      it "in #{lingua} ogni opzione ha il nome del catalogo e nessuna resta senza traduzione" do
        owner.update!(locale: lingua.to_s)

        get member_alerting_rules_path

        select = Nokogiri::HTML(response.body).at_css("[data-test='alerting-filter-event']")
        expect(select).not_to be_nil
        etichette = select.css("option").to_h { |o| [ o["value"], o.text.strip ] }
        attesi.each { |evento, nome| expect(etichette[evento.to_s]).to eq(nome) }
        expect(etichette.values).not_to include(a_string_matching(/translation missing/i))
        Alerting::Rule.event_types.keys.each do |evento|
          expect(etichette[evento]).to eq(I18n.t("member.notifications.catalog.#{evento}.title", locale: lingua)),
            "#{lingua}: il filtro chiama #{evento} «#{etichette[evento]}» ma il modulo lo chiama diversamente"
        end
      end
    end

    it "selezionare un evento conserva il filtro e il link condivisibile" do
      create(:alerting_rule, organization: org, name: "Regola vulnerabilità", event_type: :vulnerability_new)
      create(:alerting_rule, organization: org, name: "Regola errori", event_type: :error_new)

      get member_alerting_rules_path, params: { event_type: [ "vulnerability_new" ] }

      expect(response.body).to include("Regola vulnerabilità")
      expect(response.body).not_to include("Regola errori")
      selezionata = Nokogiri::HTML(response.body).at_css("[data-test='alerting-filter-event'] option[selected]")
      expect(selezionata["value"]).to eq("vulnerability_new")
    end
  end

  describe "la gerarchia" do
    it "la pagina delle regole dice chi decide che cosa e porta alle impostazioni" do
      get member_alerting_rules_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='alerting-hierarchy']").text).to include(I18n.t("member.alerting.hierarchy.rules"))
      expect(doc.at_css("[data-test='alerting-link-preferences']")["href"]).to eq(member_notification_preferences_path)
    end

    it "la pagina delle impostazioni dice chi decide che cosa e porta alle regole" do
      get member_notification_preferences_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='alerting-hierarchy']").text).to include(I18n.t("member.alerting.hierarchy.preferences"))
      expect(doc.at_css("[data-test='alerting-link-rules']")["href"]).to eq(member_alerting_rules_path)
    end

    # The hint floats over the page in its own panel, never as loose text in the content.
    it "floats the hint in a dismissable notice, gone once the person dismissed it" do
      get member_alerting_rules_path

      notice = Nokogiri::HTML(response.body).at_css("[data-test='alerting-hierarchy-notice']")
      expect(notice.at_css("[data-test='alerting-hierarchy']")).to be_present
      expect(notice.at_css("[data-test='alerting-hierarchy-notice-dismiss']")).to be_present

      owner.update!(dismissed_notices: [ "alerting_hierarchy" ])
      get member_notification_preferences_path

      expect(Nokogiri::HTML(response.body).at_css("[data-test='alerting-hierarchy-notice']")).to be_nil
    end
  end
end
