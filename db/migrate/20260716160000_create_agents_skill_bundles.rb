# frozen_string_literal: true

# Bundle skill versionato pinnato per organizzazione (B.2): la versione autoritativa del plugin
# `closeyourit-skills` che ogni Agent Host clona per eseguire le skill in skill-mode. Additiva: non tocca
# Command/Instruction (la pipeline prompt-mode CYRA-132 resta indipendente). Singleton per organizzazione.
class CreateAgentsSkillBundles < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_skill_bundles, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false,
                                  foreign_key: { on_delete: :cascade }, index: false
      t.string :repo,    null: false # owner/name (es. bussolabs/closeyourit-skills)
      t.string :ref,     null: false # tag | sha da clonare/checkout
      t.string :version, null: false # nome directory del plugin (contratto client --plugin-dir)
      t.string :digest,  null: false # SHA del commit atteso (verifica content-addressed lato host)

      t.timestamps

      t.index :organization_id, unique: true, name: "index_agents_skill_bundles_singleton"
    end
  end
end
