# frozen_string_literal: true

# CYRA-1121 — le rotte generiche di ActiveStorage (/rails/active_storage/: redirect, proxy e le
# rappresentazioni) non servono MAI i file di ticket, commenti, domande e risposte. Quelle URL sono
# permanenti e non sanno chi le apre: un link copiato continuerebbe ad aprire il file anche dopo che
# il membro ha perso l'accesso al ticket.
#
# - file di ticket e commenti → rimando a Member::Tickets::FilesController, che ricontrolla la
#   visibilità (chi la ha ancora non perde il link; chi non è collegato arriva al login);
# - file di domande e risposte → 404: nessuna pagina li mostra, non c'è un indirizzo a cui rimandare;
# - blob senza nessun aggancio (es. allegato appena rimosso, binario in attesa del purge) → 404.
#
# Gli altri blob (icone, documenti di progetto, dataset, catture dei collaboratori, chat) restano
# serviti come prima. Agganciato ai controller di ActiveStorage da config/initializers/active_storage.rb;
# spec/requests/member/tickets/attachments_spec.rb apre ogni variante dei vecchi link e fallisce se un
# aggiornamento di Rails salta il controllo.
module RestrictedBlobServing
  extend ActiveSupport::Concern

  TICKET_RECORD_TYPES = %w[Ticketing::Ticket Ticketing::Comment].freeze
  CLOSED_RECORD_TYPES = %w[Ticketing::Question Ticketing::Answer].freeze

  included do
    # In TESTA alla catena: gira prima di set_blob e set_representation, quindi non dipende dal loro
    # ordine né lascia generare una variante di un file che non verrà servito.
    prepend_before_action :reroute_restricted_blob
  end

  private

  def reroute_restricted_blob
    blob = ActiveStorage::Blob.find_signed(params[:signed_blob_id] || params[:signed_id])
    return unless blob
    # Un blob senza aggancio non lo mostra nessuna pagina (gli upload diretti sono spenti, e i blob
    # creati dai service vengono agganciati subito): è un file appena staccato in attesa di
    # purge_later. Il vecchio link non deve tornare a servirlo, né nell'attesa né se il job fallisce.
    return head(:not_found) unless blob.attachments.exists?

    attachment = blob.attachments.find_by(record_type: TICKET_RECORD_TYPES + CLOSED_RECORD_TYPES)
    return unless attachment
    return head(:not_found) unless TICKET_RECORD_TYPES.include?(attachment.record_type)

    # I controller di ActiveStorage non vedono gli helper delle rotte dell'app: li chiediamo alla app.
    redirect_to Rails.application.routes.url_helpers.member_ticket_file_path(
      restricted_ticket_id(attachment), attachment,
      disposition: params[:disposition] == "attachment" ? "attachment" : nil
    )
  end

  def restricted_ticket_id(attachment)
    return attachment.record_id if attachment.record_type == "Ticketing::Ticket"

    Ticketing::Comment.where(id: attachment.record_id).pick(:ticket_id)
  end
end
