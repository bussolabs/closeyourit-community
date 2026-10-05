# frozen_string_literal: true

# Autenticazione a token UTENTE (account-proxy) per la CLI. Risolve Accounts::ApiToken dal digest e
# pinna Current.account + Current.organization (+ api_token). L'autorizzazione di ogni azione passa poi
# per Authorization::Resolver (permessi LIVE dell'account). Distinta da TokenAuthentication (project
# token, account nil): i due segreti si distinguono per prefisso ("cyi_" vs "cyi_u_") + tabelle diverse.
module UserTokenAuthentication
  extend ActiveSupport::Concern
  include OrganizationSuspension

  private

  def authenticate_user_token!
    token = resolve_user_bearer_token
    if token.nil?
      return render_error("R401-CLIAUTH-001", "Token CLI mancante o non valido", status: :unauthorized)
    end

    # Revocato PRIMA di scaduto: un token revocato e poi arrivato a scadenza è stato chiuso da
    # qualcuno, e quella è la notizia che conta. Dirgli "scaduto, rifai l'accesso" nasconderebbe la
    # decisione dietro un fatto del calendario. Esito identico al token sconosciuto: chi revoca vuole
    # che quel segreto non dica più niente, nemmeno "esistevo".
    if token.revoked?
      return render_error("R401-CLIAUTH-001", "Token CLI mancante o non valido", status: :unauthorized)
    end
    # CYRA-717: scaduto e "non lo conosco" sono due notizie diverse per chi sta al terminale. Chi
    # presenta un segreto valido ma scaduto deve leggere che l'accesso è finito e va rifatto, non
    # andare a cercare un errore di copia-incolla che non c'è. Nessun leak: per arrivare qui bisogna
    # già possedere il segreto.
    if token.expired?
      return render_error("R401-CLIAUTH-002", "Token CLI scaduto: esegui di nuovo l'accesso",
                          status: :unauthorized, details: { expired_at: token.expires_at.iso8601 })
    end

    Current.api_token = token
    Current.account = token.account
    Current.organization = token.organization

    # CYRA-722 — la riga di comando non è una porta di servizio: se l'organizzazione è sospesa, il
    # terminale legge lo stesso rifiuto che il browser mostra a pagina intera.
    return if reject_suspended_organization!

    # Debounce: aggiorna last_used_at solo se stantio, senza callback (hot path).
    token.update_column(:last_used_at, Time.current) if token.stale_usage?
  end

  # Risolve SENZA lo scope .active: un token scaduto o revocato deve arrivare fino al chiamante per
  # poter distinguere i due esiti. Il filtro vero resta subito sopra, in authenticate_user_token!.
  def resolve_user_bearer_token
    header = request.authorization
    return nil unless header&.start_with?("Bearer ")

    presented = header.delete_prefix("Bearer ").strip
    return nil if presented.blank?

    Accounts::ApiToken.find_by(token_digest: Digest::SHA256.hexdigest(presented))
  end
end
