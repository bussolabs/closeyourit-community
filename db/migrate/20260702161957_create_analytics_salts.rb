class CreateAnalyticsSalts < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_salts, id: :uuid do |t|
      t.timestamps

      # Giorno UTC del salt: i salt oltre ANALYTICS_SALT_RETENTION_DAYS vengono distrutti,
      # rendendo i visitor_hash storici matematicamente irreversibili.
      t.date :date, null: false
      t.string :value, null: false

      t.index :date, unique: true
    end
  end
end
