# frozen_string_literal: true

require "rails_helper"

# CYRA-745 — UN REGISTRO SOLO DA LEGGERE.
#
# Le azioni delle persone nascevano in registri separati, uno per dominio, e ognuno si leggeva (quando
# si leggeva) in un posto diverso: quello dei PERMESSI non lo apriva nessuna pagina. Il difetto non è
# che i registri siano più d'uno — i registri dei segreti sono append-only e immutabili, riscriverne lo
# storico in una tabella sola significherebbe togliere all'audit la sola cosa che lo rende un audit —
# ma che nessuno li tenesse insieme.
#
# La rete: ogni tabella di registro del prodotto o è dentro la vista unificata (Activity::AuditQuery,
# quindi leggibile dalla pagina «chi ha fatto cosa e quando»), oppure sta qui sotto con scritto perché
# no. Una tabella di registro nuova fa ROSSO finché non si prende una delle due strade, che è come si
# impedisce a un nono registro di nascere invisibile: il difetto di partenza non era la nascita di un
# registro, era che nascesse senza che nessuno lo leggesse.
RSpec.describe "Il registro delle attività è uno solo (CYRA-745)", type: :model do
  # I registri che NON entrano nella vista unificata, con la ragione. Nessuno di questi è un dominio
  # dimenticato: sono cose che non rispondono alla domanda «chi ha fatto cosa nella mia organizzazione».
  FUORI_DAL_REGISTRO = {
    # Telemetria applicativa: le occorrenze di un errore del software, non l'azione di una persona.
    "errors_events" => "sono gli errori del software, non le azioni delle persone",
    # Audit di PIATTAFORMA (chi entra nei panni di chi): appartiene a Valhalla, non all'organizzazione
    # impersonata, che non deve poter dedurre da un suo registro quando è stata guardata da dentro.
    "accounts_impersonation_events" => "è audit di piattaforma, non dell'organizzazione",
    # CYRA-135 — i due registri PERSONALI sono privati di chi li ha generati. Portarli qui aprirebbe a
    # un amministratore la cassaforte personale delle persone, che è ciò che il livello «personale»
    # promette di non fare.
    "secrets_personal_events" => "è la cassaforte personale, privata di chi la usa",
    "secrets_personal_asset_events" => "sono i file della cassaforte personale, privati di chi li usa",
    # CYAG-22: Kubernetes warnings of an observed cluster, not actions of people.
    "clusters_events" => "Kubernetes warnings of an observed cluster, not actions of people"
  }.freeze

  def tabelle_registro
    ActiveRecord::Base.connection.tables.grep(/_events\z/).sort
  end

  def tabelle_unificate
    Activity::AuditQuery::SOURCE_MODELS.values.flatten.map(&:table_name).sort
  end

  it "ogni registro del prodotto o si legge dalla pagina, o dice perché no" do
    scoperti = tabelle_registro - tabelle_unificate - FUORI_DAL_REGISTRO.keys

    expect(scoperti).to be_empty,
                        "registri che nessuna pagina legge: #{scoperti.join(', ')}.\n" \
                        "Aggiungili a Activity::AuditQuery::SOURCE_MODELS, oppure dichiara qui " \
                        "perché non rispondono a «chi ha fatto cosa e quando»."
  end

  it "non dichiara esclusioni per registri che non esistono più" do
    fantasmi = FUORI_DAL_REGISTRO.keys - tabelle_registro

    expect(fantasmi).to be_empty, "esclusioni senza tabella: #{fantasmi.join(', ')}"
  end

  it "la vista unificata legge tabelle vere" do
    expect(tabelle_unificate).to all(be_in(tabelle_registro))
    expect(tabelle_unificate.size).to eq(6)
  end

  # Il cuore del ticket, presidiato dal codice e non dalla memoria: il registro dei permessi veniva
  # scritto e nessuna pagina lo leggeva.
  it "il registro dei permessi è dentro la vista unificata" do
    expect(tabelle_unificate).to include(Authorization::Event.table_name)
  end

  # Ogni sorgente deve avere un nome leggibile nelle due lingue: una sorgente senza nome comparirebbe
  # nella colonna «Registro» come chiave di traduzione mancante.
  %i[it en].each do |lingua|
    it "ogni registro ha un nome in #{lingua}" do
      senza_nome = Activity::AuditQuery::SOURCES.reject do |source|
        I18n.t("member.activity.sources.#{source}", locale: lingua, default: nil).present?
      end

      expect(senza_nome).to be_empty, "registri senza nome in #{lingua}: #{senza_nome.join(', ')}"
    end

    # Nessuna azione può mostrare in pagina il proprio nome inglese: il verbo o è tradotto, o ricade
    # sulla parola generica del vocabolario, mai su `translation missing`.
    it "ogni azione del registro ha un verbo in #{lingua}" do
      senza_verbo = Activity::AuditQuery::SOURCES.flat_map do |source|
        next [] if source == :secrets # i verbi del Vault vivono in member.secrets.actions (CYRA-426)

        Activity::AuditQuery.actions_for(source).filter_map do |action|
          chiave = "member.activity.actions.#{source}.#{action}"
          chiave if I18n.t(chiave, locale: lingua, default: nil).blank?
        end
      end

      expect(senza_verbo).to be_empty, "azioni senza verbo in #{lingua}: #{senza_verbo.join(', ')}"
    end
  end
end
