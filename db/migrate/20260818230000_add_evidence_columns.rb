# frozen_string_literal: true

# Gli spazi vuoti dove il sistema scriverà quello che ha visto (CYRA-601).
#
# Oggi una lavorazione avanza perché l'agente scrive una frase. Perché smetta, servono dei posti
# dove annotare i fatti osservati: quale proposta di modifica il server ha aperto, quando, quante
# volte quella lavorazione è stata respinta, e che tipo di prova serve a quel repository per poter
# dire «rilasciato davvero». Questa migrazione crea solo i posti. Nessun comportamento cambia:
# nessun lettore esistente tocca queste colonne, e chi usa il prodotto non vede niente di nuovo.
#
# DUE SCELTE CHE SEMBRANO DETTAGLI E NON LO SONO.
#
# 1. `candidate_items` e `completion_probe` nascono SENZA valore di partenza, e NULL vuol dire
#    «non ancora deciso». Un default `[]` confonderebbe «non ho deciso» con «ho deciso: nessun
#    repository», e più avanti il verificatore leggerebbe una lista vuota come «li ho controllati
#    tutti» — verde su un lavoro mai guardato. È esattamente il difetto che questa lavorazione
#    esiste per togliere, e va tenuto fuori dalla prima riga.
#
# 2. `review_candidate_id` resta un uuid nudo, senza chiave esterna: la tabella a cui punterà
#    nasce dopo (T6). Una FK qui renderebbe questa migrazione non applicabile da sola.
#
# La protezione della decisione congelata NON sta qui ma nel modello (`Agents::Plan`): una guardia
# scrivi-una-volta, non `attr_readonly`. Con `load_defaults 8.1` `attr_readonly` solleva su una riga
# già salvata — cioè proprio sulla scrittura che avviene all'approvazione del piano — quindi
# bloccherebbe la scrittura giusta insieme a quelle sbagliate.
class AddEvidenceColumns < ActiveRecord::Migration[8.1]
  def change
    change_table :agents_workflows, bulk: true do |t|
      t.datetime :candidate_verified_at
      t.datetime :closer_production_completed_at
      t.datetime :plan_frozen_at
      # Punta alla riga del candidato verificato, che nasce in T6: uuid nudo, niente FK (vedi sopra).
      t.uuid :review_candidate_id
      t.uuid :frozen_plan_id
      t.integer :candidate_rejections_count, default: 0, null: false
    end

    add_index :agents_workflows, :frozen_plan_id
    add_foreign_key :agents_workflows, :agents_plans, column: :frozen_plan_id

    # Un contatore di respinte non può scendere sotto zero: se ci arriva, a sbagliare è chi lo
    # scrive, e il posto giusto per accorgersene è il momento della scrittura.
    add_check_constraint :agents_workflows,
                         "candidate_rejections_count >= 0",
                         name: "agents_workflows_candidate_rejections_count_non_negative"

    change_table :agents_plans, bulk: true do |t|
      t.jsonb :candidate_items
      t.jsonb :completion_probe
    end

    # `jsonb_typeof` distingue il NULL della colonna (assente: ammesso) dal `null` scritto DENTRO il
    # documento JSON (una decisione presa e vuota: rifiutata). Sono due cose diverse e devono restarlo.
    add_check_constraint :agents_plans,
                         "candidate_items IS NULL OR " \
                         "(jsonb_typeof(candidate_items) = 'array' AND jsonb_array_length(candidate_items) > 0)",
                         name: "agents_plans_candidate_items_non_empty_array"
    add_check_constraint :agents_plans,
                         "completion_probe IS NULL OR jsonb_typeof(completion_probe) = 'object'",
                         name: "agents_plans_completion_probe_object"
    # Le due decisioni si congelano nello stesso istante, all'approvazione. Una presente e l'altra no
    # è uno stato che nessun percorso legittimo produce: se compare, qualcuno ha scritto a metà.
    add_check_constraint :agents_plans,
                         "(candidate_items IS NULL) = (completion_probe IS NULL)",
                         name: "agents_plans_frozen_decision_together"

    # Che prova serve per dire «rilasciato» su questo repository: 0 deploy+smoke, 1 pubblicazione,
    # 2 solo unione. NULL = non ancora deciso, ed è il valore di tutti i repository esistenti: nessuno
    # diventa `deploy_smoke` per via di un valore di partenza che nessuno ha scelto.
    add_column :github_repositories, :release_probe, :integer
    add_check_constraint :github_repositories,
                         "release_probe IS NULL OR release_probe IN (0, 1, 2)",
                         name: "github_repositories_release_probe_known"
  end
end
