# frozen_string_literal: true

# L'indice unico nasceva col nome giusto e il comportamento sbagliato: si chiama
# "index_invitations_pending_per_org_email" e la migration che lo creava commentava "Un solo invito
# PENDENTE per email+organizzazione", ma senza `where` copre anche gli inviti già accettati — che non
# vengono mai cancellati. Risultato: rimossa una persona dall'organizzazione, il suo invito accettato
# restava a occupare l'email per sempre e il reinvito veniva rifiutato con "Email è già stato preso",
# da una riga che la pagina Membri non mostra nemmeno (elenca solo i pendenti).
#
# Passare da indice pieno a indice parziale è sempre sicuro: il nuovo vincolo è meno restrittivo del
# vecchio, quindi nessuna riga esistente può violarlo.
class MakeInvitationsUniqueIndexPending < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_invitations_pending_per_org_email"

  def up
    remove_index :connections_invitations, name: INDEX_NAME
    add_index :connections_invitations, [ :organization_id, :email ],
              unique: true, where: "accepted_at IS NULL", name: INDEX_NAME
  end

  def down
    remove_index :connections_invitations, name: INDEX_NAME
    add_index :connections_invitations, [ :organization_id, :email ],
              unique: true, name: INDEX_NAME
  end
end
