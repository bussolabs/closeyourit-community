# frozen_string_literal: true

# I PROPRI token CLI visti dal loro titolare (CYRA-643). Distinto da UserApiTokenSerializer, che rende
# gli stessi record dal punto di vista di chi AMMINISTRA i token di un service account: lì l'org è già
# quella del path e "corrente" non vuol dire niente. Qui la lista attraversa tutte le organizzazioni —
# un token vive in una sola, e senza il nome dell'org chi ne ha tre non sa quale sta chiudendo — e
# marca il token con cui la chiamata sta arrivando, perché revocare quello disconnette il terminale
# che si sta usando. MAI token_digest: il segreto esiste solo nella risposta alla creazione.
class AccountApiTokenSerializer < ApplicationSerializer
  attributes :id, :name, :token_prefix, :last_used_at, :expires_at, :revoked_at, :created_at

  attribute :organization do |token|
    { id: token.organization_id, name: token.organization.name }
  end

  # Il confronto è sull'id, non sull'oggetto: params porta un id perché il serializer non deve
  # dipendere da Current (che in un job o in una console non c'è).
  attribute :current do |token|
    token.id == (params && params[:current_token_id])
  end
end
