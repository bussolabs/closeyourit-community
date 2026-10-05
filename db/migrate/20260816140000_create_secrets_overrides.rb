# frozen_string_literal: true

# CYRA-79 — override PERSONALE del valore di un secret di progetto, assegnato da chi gestisce il vault
# (admin-provisioned: l'utente lo riceve, non se lo dà). Una riga dice: «per QUESTA persona, su questo
# progetto e ambiente, la variabile NAME vale questo invece del default». Il merge vive in
# Secrets::Bundle e riguarda SOLO le letture fatte da una persona (CLI): la sincronizzazione verso
# GitHub passa `account: nil` e non applica mai un override.
#
# L'identità è [destinatario, progetto, ambiente, nome] (indice unico): non c'è versioning: un override
# è una deviazione locale, il valore storicizzato resta quello della variabile di progetto.
# `created_by` è l'admin che l'ha assegnato e diventa nil se quell'account sparisce — l'override deve
# sopravvivere a chi l'ha creato, altrimenti si spegnerebbe l'ambiente di lavoro di qualcun altro.
class CreateSecretsOverrides < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_overrides, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :environment, type: :uuid, null: false,
                   foreign_key: { to_table: :types_environments, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :created_by, type: :uuid,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string :name, null: false
      t.text :value, null: false
      t.text :description

      t.index %i[account_id project_id environment_id name], unique: true,
              name: "index_secrets_overrides_on_account_project_env_name"
      t.index %i[project_id environment_id]
    end
  end
end
