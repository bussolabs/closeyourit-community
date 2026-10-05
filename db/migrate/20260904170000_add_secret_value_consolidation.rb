# frozen_string_literal: true

# CYRA-777 — «Valore in comune»: lo stesso valore segreto ricopiato a mano in più progetti della
# stessa organizzazione. Oggi il prodotto non può accorgersene, perché il valore è cifrato in modo
# NON deterministico (due copie identiche hanno ciphertext diversi): non esiste nessuna query che
# dica «questi due sono lo stesso valore» senza decifrarli tutti.
#
# `value_fingerprint` è l'impronta HMAC-SHA256 del valore in chiaro con una chiave dedicata
# (Secrets::Consolidation::Fingerprint). È una colonna in CHIARO, e questo è il punto: si può
# raggruppare in SQL. Non è reversibile e senza la chiave non si può nemmeno provare a indovinare il
# valore confrontandolo con un dizionario — che è la ragione per cui non è un semplice SHA256.
#
# `local_name` sulla delega è l'alias con cui il progetto continua a chiamare il valore dopo che è
# stato spostato nell'organizzazione: il valore è il cardine della proposta, i nomi possono differire
# da progetto a progetto e nessuno deve essere costretto a rinominare la sua variabile d'ambiente per
# accettare. nil = il progetto usa il nome del secret dell'organizzazione, cioè il comportamento di
# prima, che resta quello di tutte le deleghe già esistenti.
#
# `secrets_consolidation_suggestions` persiste la proposta invece di ricalcolarla a ogni pagina: solo
# così «Non proporre più» può essere una decisione che resta, e solo così la notifica agli
# amministratori può partire UNA volta per proposta e non a ogni giro del job.
class AddSecretValueConsolidation < ActiveRecord::Migration[8.1]
  def change
    # Impronta del valore. Nullable per costruzione: i valori vuoti o troppo corti non ne hanno una
    # (vedi Fingerprint::MIN_LENGTH), e le righe esistenti restano senza finché il backfill non passa.
    add_column :secrets_variables, :value_fingerprint, :string
    add_column :secrets_shared_values, :value_fingerprint, :string

    # L'indice che regge il raggruppamento «stesso valore, stessa organizzazione, stesso ambiente».
    # PARZIALE sulle sole righe con impronta: le altre non entrano mai nel gruppo, e tenerle
    # nell'indice lo farebbe crescere senza servire a nessuna query.
    add_index :secrets_variables, %i[organization_id environment_id value_fingerprint],
              where: "value_fingerprint IS NOT NULL",
              name: "index_secrets_variables_on_value_fingerprint"
    # Sugli shared serve la domanda inversa: «questo valore l'organizzazione ce l'ha già?». Se sì la
    # proposta è di delegare quello che esiste, non di crearne un secondo uguale.
    add_index :secrets_shared_values, %i[environment_id value_fingerprint],
              where: "value_fingerprint IS NOT NULL",
              name: "index_secrets_shared_values_on_value_fingerprint"

    add_column :secrets_shared_delegations, :local_name, :string

    create_table :secrets_consolidation_suggestions, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }
      # L'ambiente è parte dell'identità: lo stesso nome ha valori diversi in staging e in produzione,
      # e due valori diversi non sono «un valore in comune».
      t.references :environment, type: :uuid, null: false,
                   foreign_key: { to_table: :types_environments, on_delete: :cascade }
      # Il valore dell'organizzazione nato dalla proposta accettata; nil finché la proposta è aperta.
      t.references :shared_variable, type: :uuid, null: true,
                   foreign_key: { to_table: :secrets_shared_variables, on_delete: :nullify }
      t.references :dismissed_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :promoted_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      # L'impronta, MAI il valore: la proposta non è un posto dove tenere un segreto in chiaro.
      t.string  :value_fingerprint, null: false
      # enum { open: 0, dismissed: 1, promoted: 2 }
      t.integer :status, null: false, default: 0
      # Il nome proposto per il secret dell'organizzazione: il più usato fra quelli dei progetti
      # coinvolti. Ricalcolato a ogni giro finché la proposta è aperta.
      t.string  :suggested_name, null: false
      # Quanti progetti condividono il valore all'ultimo giro. Denormalizzato perché lo legge la riga
      # in «Da sistemare» e l'avviso della riga di comando, che non devono rifare il conteggio; la
      # pagina di conferma lo RICALCOLA sempre, perché lì si sta per scrivere.
      t.integer :projects_count, null: false, default: 0

      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at,  null: false
      t.datetime :dismissed_at
      t.datetime :promoted_at

      # Una proposta sola per [organizzazione, ambiente, valore]: è ciò che rende «Non proporre più»
      # una decisione definitiva invece di un rinvio fino al giro successivo.
      t.index %i[organization_id environment_id value_fingerprint],
              unique: true, name: "index_secrets_consolidation_suggestions_on_identity"
    end
  end
end
