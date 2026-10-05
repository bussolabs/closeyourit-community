# frozen_string_literal: true

# Guidance gerarchica (CYRA-74): references e procedures che l'org, il gruppo di progetti e il singolo
# progetto dichiarano una volta e che ticket, CLI, persone e automazioni CONSUMANO risolte (mai copiate
# nel testo del ticket). L'owner è polimorfico ma ristretto a tre soli tipi — Organizations::Organization,
# Projects::Group, Projects::Project — così la stessa `key` può vivere ai tre livelli e Guidance::Resolve
# comporli nearest-wins. organization_id è denormalizzato (radice di tenancy): serve alla query per tenant
# e alla validazione di coerenza, non deriva dall'owner (l'org owner NON ha organization_id, ha id).
class CreateGuidanceTables < ActiveRecord::Migration[8.1]
  def change
    # Reference = puntatore a una fonte di contesto (un repo, una pagina di knowledge base, una URL, un
    # path). `kind` è il discriminatore che dice al consumer come interpretare `location`. `required`
    # segnala che il consumer DEVE seguirla (metadato, non incide sulla risoluzione).
    create_table :guidance_references, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                                foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :organization, type: :uuid, null: false,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      # Polimorfico manuale (index: false): niente FK reale (punta a 3 tabelle), gli indici li definiamo
      # sotto — quello unique copre già il prefisso [owner_type, owner_id] per la query di risoluzione.
      t.references :owner, type: :uuid, null: false, polymorphic: true, index: false

      t.string  :key,          null: false
      # 0 repository · 1 knowledge_base · 2 url · 3 path
      t.integer :kind,         null: false, default: 0
      t.string  :location
      t.text    :instructions
      t.boolean :required,     null: false, default: false
      t.boolean :enabled,      null: false, default: true
      t.integer :position,     null: false, default: 0

      # Identità stabile: una sola reference per `key` a un dato livello (owner). La gerarchia sta nei
      # tre owner distinti, non nei duplicati sullo stesso owner. L'indice su organization_id lo crea
      # già t.references :organization.
      t.index %i[owner_type owner_id key], unique: true, name: "index_guidance_references_unique"
    end

    # Procedure = istruzione testuale (`content`) che si applica al lavoro sul progetto. A differenza
    # delle reference si può COMPORRE lungo la gerarchia: `application_mode` decide se eredita, sostituisce
    # netto o disabilita la key; `merge_strategy` decide, quando eredita, se il content del livello più
    # vicino sovrascrive o si accoda a quello ereditato. Semantica completa in Guidance::Resolve.
    create_table :guidance_procedures, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                                foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :organization, type: :uuid, null: false,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :owner, type: :uuid, null: false, polymorphic: true, index: false

      t.string  :key,              null: false
      t.text    :content,          null: false
      # 0 inherit · 1 replace · 2 disable
      t.integer :application_mode, null: false, default: 0
      # 0 override · 1 append
      t.integer :merge_strategy,   null: false, default: 0
      t.boolean :enabled,          null: false, default: true
      t.integer :position,         null: false, default: 0

      t.index %i[owner_type owner_id key], unique: true, name: "index_guidance_procedures_unique"
    end
  end
end
