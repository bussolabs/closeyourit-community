class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts, id: :uuid do |t|
      t.timestamps

      t.string  :email,           null: false
      t.string  :password_digest, null: false
      t.string  :name,            null: false
      t.boolean :god,             null: false, default: false

      t.index :email, unique: true
    end
  end
end
