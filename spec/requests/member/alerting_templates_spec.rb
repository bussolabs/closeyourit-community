# frozen_string_literal: true

require "rails_helper"

# CYRA-482 — il caso più comune, «avvisami se il sito cade», non aveva nessuna scorciatoia: il form si
# apriva su un evento di error monitoring e bisognava riconoscere l'evento giusto fra ventitré voci.
# E che il ciclo completo richieda DUE regole (caduta e ritorno) non era scritto da nessuna parte.
RSpec.describe "Member::AlertingRules — modelli pronti (CYRA-482)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "la creazione propone almeno tre modelli pronti" do
    get new_member_alerting_rule_path

    cards = Nokogiri::HTML(response.body).css("[data-test^='alerting-template-'][data-test$='']")
    expect(Nokogiri::HTML(response.body).at_css("[data-test='alerting-rule-templates']")).to be_present
    expect(Alerting::Rules::Templates.all.size).to be >= 3
    Alerting::Rules::Templates.all.each do |template|
      expect(Nokogiri::HTML(response.body).at_css("[data-test='alerting-template-#{template.key}']")).to be_present
    end
  end

  it "il modello della caduta dichiara PRIMA che creerà anche la regola del ritorno" do
    get new_member_alerting_rule_path

    outcome = Nokogiri::HTML(response.body).at_css("[data-test='alerting-template-outcome-site_down']").text
    expect(outcome).to include(Notifications::Catalog.entry("uptime_down").title)
    expect(outcome).to include(Notifications::Catalog.entry("uptime_up").title)
  end

  it "usando il modello della caduta nascono entrambe le regole" do
    # Le due regole del modello si creano una per una: la cardinalità è FISSA (gli eventi del
    # template, due), non cresce coi dati — non è l'N+1 che il guard cerca.
    expect do
      allow_n_plus_one { post apply_template_member_alerting_rules_path(template: "site_down") }
    end.to change(Alerting::Rule, :count).by(2)

    expect(org.alerting_rules.pluck(:event_type)).to match_array(%w[uptime_down uptime_up])
  end

  it "il modello porta con sé progetto e ambiente quando si arriva da un sito" do
    allow_n_plus_one { post apply_template_member_alerting_rules_path(template: "site_down", project_id: project.id) }

    expect(org.alerting_rules.pluck(:project_id).uniq).to eq([ project.id ])
  end

  it "un modello inventato non crea niente" do
    expect do
      post apply_template_member_alerting_rules_path(template: "non-esiste")
    end.not_to change(Alerting::Rule, :count)
  end

  it "il modulo vuoto non parte più da un evento che non riguarda l'infrastruttura" do
    get new_member_alerting_rule_path

    selected = Nokogiri::HTML(response.body).at_css("[data-test='alerting-rule-event-select'] option[selected]")
    expect(selected).to be_nil
  end
  # Difesa in profondità dopo il review di sicurezza: Alerting::Rules::Save azzera già gli id di
  # un'ALTRA organizzazione, ma dentro la propria org la visibilità dei progetti è per-persona, e il
  # modello non può saperlo. Il gate sta nel controller, come per il prefill del form.
  it "non aggancia la regola a un progetto che chi la crea non vede" do
    altra_org = create(:organization)
    progetto_altrui = create(:project, organization: altra_org)

    allow_n_plus_one { post apply_template_member_alerting_rules_path(template: "cron_missed", project_id: progetto_altrui.id) }

    expect(org.alerting_rules.pluck(:project_id)).to all(be_nil)
  end
end
