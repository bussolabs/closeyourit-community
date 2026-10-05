# frozen_string_literal: true

require "rails_helper"

# CYRA-800 — la pagina degli errori raggruppati era governata da un file solo: 483 righe, diciotto
# azioni e venticinque metodi privati che servivano insieme la lista, la scheda, lo smistamento,
# l'unione di gruppi, l'eliminazione e l'assegnazione. Chi toccava lo smistamento apriva lo stesso
# file di chi toccava l'unione, e viceversa.
#
# Qui si guarda il SORGENTE e le ROTTE, non il comportamento: che le parti esistano davvero, che il
# file principale non se le sia riprese e che gli indirizzi siano rimasti quelli di prima. Le prove
# di comportamento restano i request spec della pagina (spec/requests/member/monitoring/).
RSpec.describe "La pagina degli errori raggruppati non è governata da un file solo", type: :model do
  let(:controller_path) { Rails.root.join("app/controllers/member/monitoring/error_groups_controller.rb") }
  # Solo le righe di CODICE: un commento che NOMINA lo smistamento o l'unione è memoria utile e resta
  # dov'è. Quello che non deve tornare qui è la regola scritta di nuovo.
  let(:codice) { controller_path.readlines.reject { |riga| riga.strip.start_with?("#") } }

  # Gli indirizzi della Definition of Done: nome dell'helper, verbo, percorso e chi risponde. Il nome
  # e il percorso sono quelli di prima della divisione — cambiarli romperebbe view, segnalibri e
  # richieste già scritte; a cambiare è solo la colonna di destra.
  let(:indirizzi) do
    {
      "bulk_triage_member_monitoring_error_groups" =>
        [ "POST", "/member/monitoring/error/triage", "member/monitoring/error_groups/triages#bulk_triage" ],
      "merge_preview_member_monitoring_error_groups" =>
        [ "POST", "/member/monitoring/error/merge/preview", "member/monitoring/error_groups/merges#preview" ],
      "merge_member_monitoring_error_groups" =>
        [ "POST", "/member/monitoring/error/merge", "member/monitoring/error_groups/merges#create" ],
      "resolve_member_monitoring_error_group" =>
        [ "PATCH", "/member/monitoring/error/:id/resolve", "member/monitoring/error_groups/triages#resolve" ],
      "ignore_member_monitoring_error_group" =>
        [ "PATCH", "/member/monitoring/error/:id/ignore", "member/monitoring/error_groups/triages#ignore" ],
      "reopen_member_monitoring_error_group" =>
        [ "PATCH", "/member/monitoring/error/:id/reopen", "member/monitoring/error_groups/triages#reopen" ],
      "triage_ai_member_monitoring_error_group" =>
        [ "POST", "/member/monitoring/error/:id/analyze", "member/monitoring/error_groups/triages#triage_ai" ],
      "promote_member_monitoring_error_group" =>
        [ "POST", "/member/monitoring/error/:id/promote", "member/monitoring/error_groups#promote" ],
      "assign_member_monitoring_error_group" =>
        [ "PATCH", "/member/monitoring/error/:id/assign", "member/monitoring/error_groups#assign" ],
      "similar_member_monitoring_error_group" =>
        [ "POST", "/member/monitoring/error/:id/similar", "member/monitoring/error_groups#similar" ]
    }
  end

  def rotta(nome)
    Rails.application.routes.routes.find { |r| r.name == nome }
  end

  # Le azioni che un controller serve DAVVERO, lette dalle rotte. `action_methods` non va bene: ci
  # finiscono dentro anche i lettori dei class_attribute delle due concern di dichiarazione.
  def azioni_servite(controller)
    Rails.application.routes.routes
         .select { |r| r.defaults[:controller] == controller }
         .map { |r| r.defaults[:action] }.uniq
  end

  it "lo smistamento e l'unione sono classi vere, con un file ciascuna" do
    expect(defined?(Member::Monitoring::ErrorGroups::TriagesController)).to eq("constant")
    expect(defined?(Member::Monitoring::ErrorGroups::MergesController)).to eq("constant")
    expect(defined?(Member::Monitoring::ErrorGroupScoping)).to eq("constant")
  end

  # Il punto della divisione: chi deve cambiare l'unione di due gruppi apre un file che parla solo di
  # quello. Se una delle due classi tornasse a servire anche il resto, la divisione sarebbe finta.
  it "ognuna delle due serve soltanto il proprio compito" do
    expect(azioni_servite("member/monitoring/error_groups/triages"))
      .to match_array(%w[resolve ignore reopen bulk_triage triage_ai])
    expect(azioni_servite("member/monitoring/error_groups/merges"))
      .to match_array(%w[preview create])
  end

  it "gli indirizzi restano quelli di prima, con il nuovo file dietro" do
    sbagliati = indirizzi.filter_map do |nome, (verbo, percorso, destination)|
      trovata = rotta(nome)
      next "#{nome}: la rotta non esiste più" if trovata.nil?

      attuale = [ trovata.verb, trovata.path.spec.to_s.sub("(.:format)", ""),
                  "#{trovata.defaults[:controller]}##{trovata.defaults[:action]}" ]
      "#{nome}: #{attuale.inspect} invece di #{[ verbo, percorso, destination ].inspect}" \
        unless attuale == [ verbo, percorso, destination ]
    end

    expect(sbagliati).to be_empty, <<~MESSAGGIO
      Questi indirizzi non sono più quelli di prima:

      #{sbagliati.join("\n")}
    MESSAGGIO
  end

  # Le grafie che dicono «lo smistamento e l'unione sono tornati nella lista». Non sono divieti di
  # stile: ognuna è il cuore di una delle parti estratte, e ritrovarla qui significa che ne esistono
  # di nuovo due copie.
  {
    "lo smistamento (risolvi, ignora, riapri, e quello a più gruppi insieme)" =>
      [ "Errors::Triage", "Errors::BulkTriage", "triageable_error_group_ids" ],
    "l'unione di due gruppi (selezione validata, primario, fusione)" =>
      [ "Errors::Merge", "mergeable_selection", "merge_refused" ]
  }.each do |compito, grafie|
    it "il file principale non riscrive più #{compito}" do
      tornate = grafie.select { |grafia| codice.any? { |riga| riga.include?(grafia) } }

      expect(tornate).to be_empty,
                         "Queste grafie sono tornate nel controller: #{tornate.join(', ')}. " \
                         "Vivono nel file che ha quel compito, non qui."
    end
  end

  # I permessi sono l'altra metà della Definition of Done: la divisione non deve aver lasciato
  # scoperta un'azione che prima era gated. `require_permission!` arriva dal concern condiviso per lo
  # smistamento e sta inline nell'unione, dove il progetto si conosce solo dopo aver risolto il
  # primario.
  it "nessuna delle parti estratte è nata senza gate né motivo scritto" do
    [ Member::Monitoring::ErrorGroups::TriagesController,
      Member::Monitoring::ErrorGroups::MergesController ].each do |klass|
      sorgenti = klass.ancestors.take_while { |modulo| modulo != Member::BaseController }
                      .filter_map { |modulo| modulo.name.presence && Object.const_source_location(modulo.name)&.first }
                      .select { |percorso| percorso.to_s.start_with?(Rails.root.join("app").to_s) }.uniq

      chiede = sorgenti.any? do |percorso|
        File.readlines(percorso).grep_v(/\A\s*#/).join.include?("require_permission!")
      end

      expect(chiede).to be(true), "#{klass.name} non interroga nessun permesso"
    end
  end
end
