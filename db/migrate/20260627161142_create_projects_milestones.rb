class CreateProjectsMilestones < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_milestones, id: :uuid do |t|
      t.timestamps
      # created_by → nullify alla cancellazione account (la milestone sopravvive).
      t.references :created_by, type: :uuid, null: true, foreign_key: { to_table: :accounts, on_delete: :nullify }
      # Scoped al PROGETTO (non all'org): ogni progetto ha la sua roadmap/release indipendente.
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects }

      t.string  :code,  null: false
      t.string  :label, null: false
      t.string  :color, null: false
      t.date    :due_on              # data target opzionale (es. v2.0 — entro 30/09)
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0

      t.index %i[project_id code], unique: true   # code unico PER PROGETTO
      t.index %i[project_id active position]
    end
  end
end
