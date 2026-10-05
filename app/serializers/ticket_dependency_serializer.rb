# frozen_string_literal: true

# Dipendenza (prerequisito) di un ticket per la CLI (CYRA-83): la voce è la relazione A→B, ma i dati
# esposti sono del BLOCKER B (ciò che va risolto prima di A). `id` è l'UUID della dipendenza — l'handle
# per il DELETE REST (.../dependencies/:id), non un dato del blocker, quindi resta anche quando il
# blocker è oscurato (chi vede A può comunque rimuovere la dipendenza). `done` = il blocker è in uno
# status della category "done" (category_done?, mai per code/label personalizzabili). `status` espone
# id+code+category STABILI per l'automazione oltre alla label. Nessun N+1: l'index precarica
# blocker→status (spec Prosopite sulla collection). `done`/`status` sono uno SNAPSHOT.
#
# Anti-BOLA in LETTURA (parità col web, CYRA-82): un blocker cross-project in un progetto NON visibile
# conserva il FATTO (esiste un prerequisito) e il suo STATO (status/done: lo status è org-wide, non
# rivela il progetto), ma nasconde l'IDENTITÀ (blocker_id/code/title → null) → niente leak intra-org.
# `hidden` segnala l'oscuramento al client.
class TicketDependencySerializer < ApplicationSerializer
  attribute(:id) { |dependency| dependency.id }
  attribute(:hidden) { |dependency| !StatusReference.blocker_visible?(dependency, params) }
  attribute(:blocker_id) { |dependency| StatusReference.blocker_visible?(dependency, params) ? dependency.blocker_id : nil }
  attribute(:code) { |dependency| StatusReference.blocker_visible?(dependency, params) ? dependency.blocker.code : nil }
  attribute(:title) { |dependency| StatusReference.blocker_visible?(dependency, params) ? dependency.blocker.title : nil }
  attribute(:status) { |dependency| StatusReference.for(dependency.blocker.status) }
  attribute(:done) { |dependency| dependency.blocker.status&.category_done? || false }
end
